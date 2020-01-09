CloudFormation do

  Condition("EnableReader", FnEquals(Ref("EnableReader"), 'true'))
  Condition("UseUsernameAndPassword", FnEquals(Ref(:SnapshotID), ''))
  Condition("UseSnapshotID", FnNot(FnEquals(Ref(:SnapshotID), '')))

  aurora_tags = []
  tags = external_parameters.fetch(:tags, {})
  aurora_tags << { Key: 'Name', Value: FnSub("${EnvironmentName}-#{external_parameters[:component_name]}") }
  aurora_tags << { Key: 'Environment', Value: Ref(:EnvironmentName) }
  aurora_tags << { Key: 'EnvironmentType', Value: Ref(:EnvironmentType) }
  aurora_tags.push(*tags.map {|k,v| {Key: k, Value: FnSub(v)}}).uniq { |h| h[:Key] }

  ingress = []
  security_group_rules = external_parameters.fetch(:security_group_rules, [])
  security_group_rules.each do |rule|
    sg_rule = {
      FromPort: cluster_port,
      IpProtocol: 'TCP',
      ToPort: cluster_port,
    }
    if rule['security_group_id']
      sg_rule['SourceSecurityGroupId'] = FnSub(rule['security_group_id'])
    else 
      sg_rule['CidrIp'] = FnSub(rule['ip']) 
    end
    if rule['desc']
      sg_rule['Description'] = FnSub(rule['desc'])
    end
    ingress << sg_rule
  end

  EC2_SecurityGroup(:SecurityGroup) do
    VpcId Ref('VPCId')
    GroupDescription FnSub("Aurora postgres #{external_parameters[:component_name]} access for the ${EnvironmentName} environment")
    SecurityGroupIngress ingress if ingress.any?
    SecurityGroupEgress ([
      {
        CidrIp: "0.0.0.0/0",
        Description: "outbound all for ports",
        IpProtocol: -1,
      }
    ]) 
    Tags aurora_tags
  end

  RDS_DBSubnetGroup(:DBClusterSubnetGroup) {
    SubnetIds Ref('SubnetIds')
    DBSubnetGroupDescription FnSub("Aurora postgres #{external_parameters[:component_name]} subnets for the ${EnvironmentName} environment")
    Tags aurora_tags
  }

  RDS_DBClusterParameterGroup(:DBClusterParameterGroup) {
    Description FnSub("Aurora postgres #{external_parameters[:component_name]} cluster parameters for the ${EnvironmentName} environment")
    Family external_parameters[:family]
    Parameters external_parameters[:cluster_parameters]
    Tags aurora_tags
  }

  engine_version = external_parameters.fetch(:engine_version, nil)
  storage_encrypted = external_parameters.fetch(:storage_encrypted, false)
  kms = external_parameters.fetch(:kms, false)
  RDS_DBCluster(:DBCluster) {
    Engine 'aurora-postgresql'
    EngineVersion engine_version unless engine_version.nil?
    DBClusterParameterGroupName Ref(:DBClusterParameterGroup)
    SnapshotIdentifier Ref(:SnapshotID)
    SnapshotIdentifier FnIf('UseSnapshotID',Ref(:SnapshotID), Ref('AWS::NoValue'))
    MasterUsername  FnIf('UseUsernameAndPassword', FnJoin('', [ '{{resolve:ssm:', FnSub(external_parameters[:master_login]['username_ssm_param']), ':1}}' ]), Ref('AWS::NoValue'))
    MasterUserPassword FnIf('UseUsernameAndPassword', FnJoin('', [ '{{resolve:ssm-secure:', FnSub(external_parameters[:master_login]['password_ssm_param']), ':1}}' ]), Ref('AWS::NoValue'))
    DBSubnetGroupName Ref(:DBClusterSubnetGroup)
    VpcSecurityGroupIds [ Ref(:SecurityGroup) ]
    StorageEncrypted storage_encrypted
    KmsKeyId Ref('KmsKeyId') if kms
    Port external_parameters[:cluster_port]
    Tags aurora_tags
  }

  instance_parameters = external_parameters.fetch(:instance_parameters, nil)
  RDS_DBParameterGroup(:DBInstanceParameterGroup) {
    Description FnSub("Aurora postgres #{external_parameters[:component_name]} instance parameters for the ${EnvironmentName} environment")
    Family external_parameters[:family]
    Parameters instance_parameters unless instance_parameters.nil?
    Tags aurora_tags
  }

  RDS_DBInstance(:DBClusterInstanceWriter) {
    DBSubnetGroupName Ref(:DBClusterSubnetGroup)
    DBParameterGroupName Ref(:DBInstanceParameterGroup)
    DBClusterIdentifier Ref(:DBCluster)
    Engine 'aurora-postgresql'
    EngineVersion engine_version unless engine_version.nil?
    PubliclyAccessible 'false'
    DBInstanceClass Ref(:WriterInstanceType)
    Tags aurora_tags
  }

  RDS_DBInstance(:DBClusterInstanceReader) {
    Condition(:EnableReader)
    DBSubnetGroupName Ref(:DBClusterSubnetGroup)
    DBParameterGroupName Ref(:DBInstanceParameterGroup)
    DBClusterIdentifier Ref(:DBCluster)
    Engine 'aurora-postgresql'
    EngineVersion engine_version unless engine_version.nil?
    PubliclyAccessible 'false'
    DBInstanceClass Ref(:ReaderInstanceType)
    Tags aurora_tags
  }
  
  Route53_RecordSet(:DBClusterReaderRecord) {
    Condition(:EnableReader)
    HostedZoneName FnJoin('', [ Ref('EnvironmentName'), '.', Ref('DnsDomain'), '.'])
    Name FnJoin('', [ external_parameters[:hostname_read_endpoint], '.', Ref('EnvironmentName'), '.', Ref('DnsDomain'), '.' ])
    Type 'CNAME'
    TTL '60'
    ResourceRecords [ FnGetAtt('DBCluster','ReadEndpoint.Address') ]
  }

  Route53_RecordSet(:DBHostRecord) {
    HostedZoneName FnJoin('', [ Ref('EnvironmentName'), '.', Ref('DnsDomain'), '.'])
    Name FnJoin('', [ external_parameters[:hostname], '.', Ref('EnvironmentName'), '.', Ref('DnsDomain'), '.' ])
    Type 'CNAME'
    TTL '60'
    ResourceRecords [ FnGetAtt('DBCluster','Endpoint.Address') ]
  }

end
