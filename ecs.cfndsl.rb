CloudFormation do

  Description "#{component_name} - #{component_version}"

  ECS_Cluster('EcsCluster') {
    ClusterName FnSub("${EnvironmentName}-#{cluster_name}") if defined? cluster_name
    Tags([
      { Key: 'Name', Value: FnSub("${EnvironmentName}-#{component_name}") },
      { Key: 'EnvironmentName', Value: Ref("EnvironmentName") },
      { Key: 'EnvironmentType', Value: Ref("EnvironmentType") }
    ])
  }

  if enable_ec2_cluster

    Condition('IsScalingEnabled', FnEquals(Ref('EnableScaling'), 'true'))
    Condition("SpotPriceSet", FnNot(FnEquals(Ref('SpotPrice'), '')))
    Condition('KeyNameSet', FnNot(FnEquals(Ref('KeyName'), '')))

    asg_ecs_tags = []
    asg_ecs_tags << { Key: 'Name', Value: FnJoin('-', [ Ref(:EnvironmentName), component_name, 'xx' ]), PropagateAtLaunch: true }
    asg_ecs_tags << { Key: 'EnvironmentName', Value: Ref(:EnvironmentName), PropagateAtLaunch: true}
    asg_ecs_tags << { Key: 'EnvironmentType', Value: Ref(:EnvironmentType), PropagateAtLaunch: true }
    asg_ecs_tags << { Key: 'Role', Value: "ecs", PropagateAtLaunch: true }

    asg_ecs_extra_tags = []
    ecs_extra_tags.each { |key,value| asg_ecs_extra_tags << { Key: "#{key}", Value: value, PropagateAtLaunch: true } } if defined? ecs_extra_tags


    asg_ecs_tags = (asg_ecs_extra_tags + asg_ecs_tags).uniq { |h| h[:Key] }

    EC2_SecurityGroup('SecurityGroupEcs') do
      GroupDescription FnJoin(' ', [ Ref('EnvironmentName'), component_name ])
      VpcId Ref('VPCId')
      Metadata({
        cfn_nag: {
          rules_to_suppress: [
            { id: 'F1000', reason: 'adding rules using cfn resources' }
          ]
        }
      })
    end

    EC2_SecurityGroupIngress('LoadBalancerIngressRule') do
      Description 'Ephemeral port range for ECS'
      IpProtocol 'tcp'
      FromPort '32768'
      ToPort '65535'
      GroupId FnGetAtt('SecurityGroupEcs','GroupId')
      SourceSecurityGroupId Ref('SecurityGroupLoadBalancer')
    end

    EC2_SecurityGroupIngress('BastionIngressRule') do
      Description 'SSH access from bastion'
      IpProtocol 'tcp'
      FromPort '22'
      ToPort '22'
      GroupId FnGetAtt('SecurityGroupEcs','GroupId')
      SourceSecurityGroupId Ref('SecurityGroupBastion')
    end

    policies = []
    iam_policies.each do |name,policy|
      policies << iam_policy_allow(name,policy['action'],policy['resource'] || '*')
    end if defined? iam_policies

    Role('Role') do
      AssumeRolePolicyDocument service_role_assume_policy('ec2')
      Path '/'
      Policies(policies)
      Metadata({
        cfn_nag: {
          rules_to_suppress: [
            { id: 'F3', reason: 'future considerations to further define the describe permisions' }
          ]
        }
      })
    end

    InstanceProfile('InstanceProfile') do
      Path '/'
      Roles [Ref('Role')]
    end

    user_data = []
    user_data << "#!/bin/bash\n"
    user_data << "INSTANCE_ID=$(/opt/aws/bin/ec2-metadata --instance-id|/usr/bin/awk '{print $2}')\n"
    user_data << "hostname "
    user_data << Ref("EnvironmentName")
    user_data << "-ecs-${INSTANCE_ID}\n"
    user_data << "sed '/HOSTNAME/d' /etc/sysconfig/network > /tmp/network && mv -f /tmp/network /etc/sysconfig/network && echo \"HOSTNAME="
    user_data << Ref('EnvironmentName')
    user_data << "-ecs-${INSTANCE_ID}\" >>/etc/sysconfig/network && /etc/init.d/network restart\n"
    user_data << "echo ECS_CLUSTER="
    user_data << Ref("EcsCluster")
    user_data << " >> /etc/ecs/ecs.config\n"
    if enable_efs
      user_data << "mkdir /efs\n"
      user_data << "yum install -y nfs-utils\n"
      user_data << "mount -t nfs4 -o nfsvers=4.1,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2 "
      user_data << Ref("FileSystem")
      user_data << ".efs."
      user_data << Ref("AWS::Region")
      user_data << ".amazonaws.com:/ /efs\n"

    end
    if enable_rex_ray_plugin

      user_data << "exec 2>>/var/log/ecs/ecs-agent-install.log\n"
      user_data << "set -x\n"
      user_data << "until curl -s http://localhost:51678/v1/metadata\n"
      user_data << "do\n"
      user_data << " sleep 1\n"
      user_data << "done\n"
      user_data << "docker plugin install rexray/ebs REXRAY_PREEMPT=true EBS_REGION="
      user_data << Ref("AWS::Region")
      user_data << " --grant-all-permissions\n"
      user_data << "stop ecs\n" 
      user_data << "start ecs\n"
    end

    ecs_agent_extra_config.each do |key, value|
      user_data << "echo #{key}=#{value}"
      user_data << " >> /etc/ecs/ecs.config\n"
    end if defined? ecs_agent_extra_config

    ecs_additional_userdata.each do |user_data_line|
      user_data << "#{user_data_line}\n"
    end if defined? ecs_additional_userdata

    volumes = []
    volumes << {
      DeviceName: '/dev/xvda',
      Ebs: {
        VolumeSize: volume_size
      }
    } if defined? volume_size

    LaunchConfiguration('LaunchConfig') do
      ImageId Ref('Ami')
      BlockDeviceMappings volumes if defined? volume_size
      InstanceType Ref('InstanceType')
      AssociatePublicIpAddress false
      IamInstanceProfile Ref('InstanceProfile')
      KeyName FnIf('KeyNameSet', Ref('KeyName'), Ref('AWS::NoValue'))
      SecurityGroups [ Ref('SecurityGroupEcs') ]
      SpotPrice FnIf('SpotPriceSet', Ref('SpotPrice'), Ref('AWS::NoValue'))
      UserData FnBase64(FnJoin('',user_data))
    end


    AutoScalingGroup('AutoScaleGroup') do
      UpdatePolicy(asg_update_policy.keys[0], asg_update_policy.values[0]) if defined? asg_update_policy
      LaunchConfigurationName Ref('LaunchConfig')
      HealthCheckGracePeriod '500'
      MinSize Ref('AsgMin')
      MaxSize Ref('AsgMax')
      VPCZoneIdentifier Ref('SubnetIds')
      Tags asg_ecs_tags
    end

    Logs_LogGroup('LogGroup') {
      LogGroupName Ref('AWS::StackName')
      RetentionInDays "#{log_group_retention}"
    }

    if defined?(ecs_autoscale)

      if ecs_autoscale.has_key?('custom_scaling')

        default_alarm = {}
        default_alarm['statistic'] = 'Average'
        default_alarm['period'] = '60'
        default_alarm['evaluation_periods'] = '5'

        CloudWatch_Alarm(:ServiceScaleUpAlarm) {
          Condition 'IsScalingEnabled'
          AlarmDescription FnJoin(' ', [Ref('EnvironmentName'), "#{component_name} ecs scale up alarm"])
          MetricName ecs_autoscale['custom_scaling']['up']['metric_name']
          Namespace ecs_autoscale['custom_scaling']['up']['namespace']
          Statistic ecs_autoscale['custom_scaling']['up']['statistic'] || default_alarm['statistic']
          Period (ecs_autoscale['custom_scaling']['up']['period'] || default_alarm['period']).to_s
          EvaluationPeriods ecs_autoscale['custom_scaling']['up']['evaluation_periods'].to_s
          Threshold ecs_autoscale['custom_scaling']['up']['threshold'].to_s
          AlarmActions [Ref(:ScaleUpPolicy)]
          ComparisonOperator 'GreaterThanThreshold'
          Dimensions ecs_autoscale['custom_scaling']['up']['dimensions']
        }

        CloudWatch_Alarm(:ServiceScaleDownAlarm) {
          Condition 'IsScalingEnabled'
          AlarmDescription FnJoin(' ', [Ref('EnvironmentName'), "#{component_name} ecs scale down alarm"])
          MetricName ecs_autoscale['custom_scaling']['down']['metric_name']
          Namespace ecs_autoscale['custom_scaling']['down']['namespace']
          Statistic ecs_autoscale['custom_scaling']['down']['statistic'] || default_alarm['statistic']
          Period (ecs_autoscale['custom_scaling']['down']['period'] || default_alarm['period']).to_s
          EvaluationPeriods ecs_autoscale['custom_scaling']['down']['evaluation_periods'].to_s
          Threshold ecs_autoscale['custom_scaling']['down']['threshold'].to_s
          AlarmActions [Ref(:ScaleDownPolicy)]
          ComparisonOperator 'LessThanThreshold'
          Dimensions ecs_autoscale['custom_scaling']['down']['dimensions']
        }
      end

      if ecs_autoscale.has_key?('memory_high')

        Resource("MemoryReservationAlarmHigh") {
          Condition 'IsScalingEnabled'
          Type 'AWS::CloudWatch::Alarm'
          Property('AlarmDescription', "Scale-up if MemoryReservation > #{ecs_autoscale['memory_high']}% for 2 minutes")
          Property('MetricName','MemoryReservation')
          Property('Namespace','AWS/ECS')
          Property('Statistic', 'Maximum')
          Property('Period', '60')
          Property('EvaluationPeriods', '2')
          Property('Threshold', ecs_autoscale['memory_high'])
          Property('AlarmActions', [ Ref('ScaleUpPolicy') ])
          Property('Dimensions', [
            {
              'Name' => 'ClusterName',
              'Value' => Ref('EcsCluster')
            }
          ])
          Property('ComparisonOperator', 'GreaterThanThreshold')
        }

        Resource("MemoryReservationAlarmLow") {
          Condition 'IsScalingEnabled'
          Type 'AWS::CloudWatch::Alarm'
          Property('AlarmDescription', "Scale-down if MemoryReservation < #{ecs_autoscale['memory_low']}%")
          Property('MetricName','MemoryReservation')
          Property('Namespace','AWS/ECS')
          Property('Statistic', 'Maximum')
          Property('Period', '60')
          Property('EvaluationPeriods', '2')
          Property('Threshold', ecs_autoscale['memory_low'])
          Property('AlarmActions', [ Ref('ScaleDownPolicy') ])
          Property('Dimensions', [
            {
              'Name' => 'ClusterName',
              'Value' => Ref('EcsCluster')
            }
          ])
          Property('ComparisonOperator', 'LessThanThreshold')
        }

      end

      if ecs_autoscale.has_key?('cpu_high')

        Resource("CPUReservationAlarmHigh") {
          Condition 'IsScalingEnabled'
          Type 'AWS::CloudWatch::Alarm'
          Property('AlarmDescription', "Scale-up if CPUReservation > #{ecs_autoscale['cpu_high']}%")
          Property('MetricName','CPUReservation')
          Property('Namespace','AWS/ECS')
          Property('Statistic', 'Maximum')
          Property('Period', '60')
          Property('EvaluationPeriods', '2')
          Property('Threshold', ecs_autoscale['cpu_high'])
          Property('AlarmActions', [ Ref('ScaleUpPolicy') ])
          Property('Dimensions', [
            {
              'Name' => 'ClusterName',
              'Value' => Ref('EcsCluster')
            }
          ])
          Property('ComparisonOperator', 'GreaterThanThreshold')
        }

        Resource("CPUReservationAlarmLow") {
          Condition 'IsScalingEnabled'
          Type 'AWS::CloudWatch::Alarm'
          Property('AlarmDescription', "Scale-up if CPUReservation < #{ecs_autoscale['cpu_low']}%")
          Property('MetricName','CPUReservation')
          Property('Namespace','AWS/ECS')
          Property('Statistic', 'Maximum')
          Property('Period', '60')
          Property('EvaluationPeriods', '2')
          Property('Threshold', ecs_autoscale['cpu_low'])
          Property('AlarmActions', [ Ref('ScaleDownPolicy') ])
          Property('Dimensions', [
            {
              'Name' => 'ClusterName',
              'Value' => Ref('EcsCluster')
            }
          ])
          Property('ComparisonOperator', 'LessThanThreshold')
        }

      end

      Resource("ScaleUpPolicy") {
        Condition 'IsScalingEnabled'
        Type 'AWS::AutoScaling::ScalingPolicy'
        Property('AdjustmentType', 'ChangeInCapacity')
        Property('AutoScalingGroupName', Ref('AutoScaleGroup'))
        Property('Cooldown','300')
        Property('ScalingAdjustment', ecs_autoscale['scale_up_adjustment'])
      }

      Resource("ScaleDownPolicy") {
        Condition 'IsScalingEnabled'
        Type 'AWS::AutoScaling::ScalingPolicy'
        Property('AdjustmentType', 'ChangeInCapacity')
        Property('AutoScalingGroupName', Ref('AutoScaleGroup'))
        Property('Cooldown','300')
        Property('ScalingAdjustment', ecs_autoscale['scale_down_adjustment'])
      }
    end

    Output('EcsSecurityGroup') {
      Value(Ref('SecurityGroupEcs'))
      Export FnSub("${EnvironmentName}-#{component_name}-EcsSecurityGroup")
    }

  end

  Output("EcsCluster") {
    Value(Ref('EcsCluster'))
    Export FnSub("${EnvironmentName}-#{component_name}-EcsCluster")
  }
  Output("EcsClusterArn") {
    Value(FnGetAtt('EcsCluster','Arn'))
    Export FnSub("${EnvironmentName}-#{component_name}-EcsClusterArn")
  }

  if enable_ec2_cluster
    Output("AutoScalingGroupName") {
      Value(Ref('AutoScaleGroup'))
      Export FnSub("${EnvironmentName}-#{component_name}-AutoScalingGroupName")
    }
  end

end
