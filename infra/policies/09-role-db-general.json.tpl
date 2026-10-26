{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ReadOnlyRDSVisibility",
      "Effect": "Allow",
      "Action": [
        "rds:Describe*",
        "rds:ListTagsForResource",
        "cloudwatch:GetMetricData",
        "cloudwatch:ListMetrics",
        "logs:GetLogEvents",
        "logs:StartQuery",
        "logs:GetQueryResults",
        "logs:DescribeLogGroups",
        "logs:DescribeLogStreams"
      ],
      "Resource": "*"
    },
    {
      "Sid": "AllowIAMDatabaseAuthDbGeneral",
      "Effect": "Allow",
      "Action": "rds-db:connect",
      "Resource": "arn:aws:rds-db:*:${account_id}:dbuser:${db_resource_id}/general_user_readonly"
    },
    {
      "Sid": "AllowSSMRdsBastionOnly",
      "Effect": "Allow",
      "Action": "ssm:StartSession",
      "Resource": [
        "arn:aws:ec2:*:${account_id}:instance/${rds_bastion_instance_id}",
        "arn:aws:ssm:*:${account_id}:document/AWS-StartPortForwardingSessionToRemoteHost"
      ]
    },
    {
      "Sid": "DenyNonBastionSSMTargets",
      "Effect": "Deny",
      "Action": "ssm:StartSession",
      "NotResource": [
        "arn:aws:ec2:*:${account_id}:instance/${rds_bastion_instance_id}",
        "arn:aws:ssm:*:${account_id}:document/AWS-StartPortForwardingSessionToRemoteHost"
      ]
    },
    {
      "Sid": "TerminateOwnSSMSessionsOnly",
      "Effect": "Allow",
      "Action": ["ssm:TerminateSession", "ssm:ResumeSession"],
      "Resource": "arn:aws:ssm:*:${account_id}:session/$${aws:userid}-*"
    },
    {
      "Sid": "AllowOpenDataChannelOwnSessionOnly",
      "Effect": "Allow",
      "Action": "ssmmessages:OpenDataChannel",
      "Resource": "arn:aws:ssm:*:*:session/$${aws:userid}-*"
    }
  ]
}
