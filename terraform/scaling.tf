# Scaling, cost control and alerting for Moodle 5.3 LTS
#
# - SNS topic for scaling/cost alerts (+ optional email subscriptions)
# - AWS Budgets monthly cost budget
# - CloudWatch alarms (disk, EC2 CPU/credits, RDS CPU/memory/storage)
# - EBS autogrow: alarm -> EventBridge rule -> SSM Automation (grow volume + filesystem)
# - Compute autoresize: EventBridge Scheduler -> SSM Automation (notify or apply one-step upsize)
#
# Automations never downsize and never go beyond the last item of each ladder.

data "aws_partition" "current" {}

locals {
  scaling_region    = data.aws_region.current.name
  scaling_account   = data.aws_caller_identity.current.account_id
  scaling_partition = data.aws_partition.current.partition

  rds_identifier = var.create_rds ? aws_db_instance.moodle[0].identifier : ""

  # Fixed alarm thresholds not exposed as variables
  rds_freeable_memory_low_bytes = 128 * 1024 * 1024
  rds_free_storage_low_bytes    = 2 * 1024 * 1024 * 1024

  budget_notifications = length(var.scaling_alert_emails) > 0 ? [
    { type = "ACTUAL", threshold = 50 },
    { type = "ACTUAL", threshold = 80 },
    { type = "ACTUAL", threshold = 100 },
    { type = "FORECASTED", threshold = 100 },
  ] : []

  ebs_autogrow_doc_name       = "${local.name_prefix}-ebs-autogrow"
  compute_autoresize_doc_name = "${local.name_prefix}-compute-autoresize"

  ssm_run_shell_script_arn = "arn:${local.scaling_partition}:ssm:${local.scaling_region}::document/AWS-RunShellScript"
}

#############################################
# SNS Topic
#############################################

resource "aws_sns_topic" "scaling_alerts" {
  name = "${local.name_prefix}-scaling-alerts"

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-scaling-alerts" })
}

resource "aws_sns_topic_policy" "scaling_alerts" {
  arn = aws_sns_topic.scaling_alerts.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AccountOwnerAccess"
        Effect    = "Allow"
        Principal = { AWS = "arn:${local.scaling_partition}:iam::${local.scaling_account}:root" }
        Action = [
          "sns:Publish",
          "sns:Subscribe",
          "sns:GetTopicAttributes",
          "sns:SetTopicAttributes",
          "sns:ListSubscriptionsByTopic",
        ]
        Resource = aws_sns_topic.scaling_alerts.arn
      },
      {
        Sid       = "AllowServicePublish"
        Effect    = "Allow"
        Principal = { Service = ["budgets.amazonaws.com", "cloudwatch.amazonaws.com"] }
        Action    = "sns:Publish"
        Resource  = aws_sns_topic.scaling_alerts.arn
        Condition = {
          StringEquals = { "aws:SourceAccount" = local.scaling_account }
        }
      },
    ]
  })
}

resource "aws_sns_topic_subscription" "scaling_alerts_email" {
  for_each = toset(var.scaling_alert_emails)

  topic_arn = aws_sns_topic.scaling_alerts.arn
  protocol  = "email"
  endpoint  = each.value
}

#############################################
# AWS Budgets
#############################################

resource "aws_budgets_budget" "monthly" {
  name         = "${local.name_prefix}-monthly-budget"
  budget_type  = "COST"
  limit_amount = format("%.2f", var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  # Notifications are only created when there are recipients
  dynamic "notification" {
    for_each = local.budget_notifications

    content {
      comparison_operator        = "GREATER_THAN"
      threshold                  = notification.value.threshold
      threshold_type             = "PERCENTAGE"
      notification_type          = notification.value.type
      subscriber_email_addresses = var.scaling_alert_emails
      subscriber_sns_topic_arns  = [aws_sns_topic.scaling_alerts.arn]
    }
  }

  depends_on = [aws_sns_topic_policy.scaling_alerts]
}

#############################################
# CloudWatch Alarms
#############################################

# Requires the CloudWatch agent config from scripts/07-setup-monitoring.sh
# (namespace CWAgent, aggregation dimensions InstanceId + path)
resource "aws_cloudwatch_metric_alarm" "moodledata_disk_high" {
  alarm_name          = "${local.name_prefix}-moodledata-disk-high"
  alarm_description   = "Disk usage of /moodledata above ${var.ebs_autogrow_threshold_percent}%"
  namespace           = "CWAgent"
  metric_name         = "disk_used_percent"
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 2
  threshold           = var.ebs_autogrow_threshold_percent
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    InstanceId = aws_instance.moodle.id
    path       = "/moodledata"
  }

  alarm_actions = [aws_sns_topic.scaling_alerts.arn]
  ok_actions    = [aws_sns_topic.scaling_alerts.arn]

  tags = local.common_tags
}

resource "aws_cloudwatch_metric_alarm" "ec2_cpu_high" {
  alarm_name          = "${local.name_prefix}-ec2-cpu-high"
  alarm_description   = "EC2 average CPU above ${var.cpu_high_threshold_percent}% for 30 minutes"
  namespace           = "AWS/EC2"
  metric_name         = "CPUUtilization"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 6
  threshold           = var.cpu_high_threshold_percent
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "missing"

  dimensions = {
    InstanceId = aws_instance.moodle.id
  }

  alarm_actions = [aws_sns_topic.scaling_alerts.arn]
  ok_actions    = [aws_sns_topic.scaling_alerts.arn]

  tags = local.common_tags
}

resource "aws_cloudwatch_metric_alarm" "ec2_cpu_credits_low" {
  alarm_name          = "${local.name_prefix}-ec2-cpu-credits-low"
  alarm_description   = "EC2 CPU credit balance below ${var.cpu_credit_low_threshold}"
  namespace           = "AWS/EC2"
  metric_name         = "CPUCreditBalance"
  statistic           = "Minimum"
  period              = 300
  evaluation_periods  = 3
  threshold           = var.cpu_credit_low_threshold
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "missing"

  dimensions = {
    InstanceId = aws_instance.moodle.id
  }

  alarm_actions = [aws_sns_topic.scaling_alerts.arn]
  ok_actions    = [aws_sns_topic.scaling_alerts.arn]

  tags = local.common_tags
}

resource "aws_cloudwatch_metric_alarm" "rds_cpu_high" {
  count = var.create_rds ? 1 : 0

  alarm_name          = "${local.name_prefix}-rds-cpu-high"
  alarm_description   = "RDS average CPU above ${var.cpu_high_threshold_percent}% for 30 minutes"
  namespace           = "AWS/RDS"
  metric_name         = "CPUUtilization"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 6
  threshold           = var.cpu_high_threshold_percent
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "missing"

  dimensions = {
    DBInstanceIdentifier = local.rds_identifier
  }

  alarm_actions = [aws_sns_topic.scaling_alerts.arn]
  ok_actions    = [aws_sns_topic.scaling_alerts.arn]

  tags = local.common_tags
}

resource "aws_cloudwatch_metric_alarm" "rds_freeable_memory_low" {
  count = var.create_rds ? 1 : 0

  alarm_name          = "${local.name_prefix}-rds-freeable-memory-low"
  alarm_description   = "RDS freeable memory below 128 MiB"
  namespace           = "AWS/RDS"
  metric_name         = "FreeableMemory"
  statistic           = "Minimum"
  period              = 300
  evaluation_periods  = 3
  threshold           = local.rds_freeable_memory_low_bytes
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "missing"

  dimensions = {
    DBInstanceIdentifier = local.rds_identifier
  }

  alarm_actions = [aws_sns_topic.scaling_alerts.arn]
  ok_actions    = [aws_sns_topic.scaling_alerts.arn]

  tags = local.common_tags
}

resource "aws_cloudwatch_metric_alarm" "rds_free_storage_low" {
  count = var.create_rds ? 1 : 0

  alarm_name          = "${local.name_prefix}-rds-free-storage-low"
  alarm_description   = "RDS free storage below 2 GiB (storage autoscaling up to db_max_allocated_storage should react first)"
  namespace           = "AWS/RDS"
  metric_name         = "FreeStorageSpace"
  statistic           = "Minimum"
  period              = 300
  evaluation_periods  = 2
  threshold           = local.rds_free_storage_low_bytes
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "missing"

  dimensions = {
    DBInstanceIdentifier = local.rds_identifier
  }

  alarm_actions = [aws_sns_topic.scaling_alerts.arn]
  ok_actions    = [aws_sns_topic.scaling_alerts.arn]

  tags = local.common_tags
}

#############################################
# IAM - Automation role: EBS autogrow
#############################################

resource "aws_iam_role" "ebs_autogrow_automation" {
  name_prefix = "${local.name_prefix}-ebs-grow-"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ssm.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = { StringEquals = { "aws:SourceAccount" = local.scaling_account } }
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy" "ebs_autogrow_automation" {
  name_prefix = "${local.name_prefix}-ebs-grow-"
  role        = aws_iam_role.ebs_autogrow_automation.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "DescribeOnly"
        Effect   = "Allow"
        Action   = ["ec2:DescribeVolumes", "ec2:DescribeVolumesModifications", "ssm:ListCommands", "ssm:ListCommandInvocations", "ssm:DescribeInstanceInformation"]
        Resource = "*"
      },
      {
        Sid      = "ModifyDataVolume"
        Effect   = "Allow"
        Action   = "ec2:ModifyVolume"
        Resource = aws_ebs_volume.moodle_data.arn
      },
      {
        Sid      = "RunShellOnMoodleInstance"
        Effect   = "Allow"
        Action   = "ssm:SendCommand"
        Resource = [aws_instance.moodle.arn, local.ssm_run_shell_script_arn]
      },
      {
        Sid      = "PublishAlerts"
        Effect   = "Allow"
        Action   = "sns:Publish"
        Resource = aws_sns_topic.scaling_alerts.arn
      },
    ]
  })
}

#############################################
# IAM - Automation role: compute autoresize
#############################################

resource "aws_iam_role" "compute_autoresize_automation" {
  name_prefix = "${local.name_prefix}-autoresize-"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ssm.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = { StringEquals = { "aws:SourceAccount" = local.scaling_account } }
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy" "compute_autoresize_automation" {
  name_prefix = "${local.name_prefix}-autoresize-"
  role        = aws_iam_role.compute_autoresize_automation.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [
        {
          Sid    = "DescribeOnly"
          Effect = "Allow"
          Action = [
            "ec2:DescribeInstances",
            "ec2:DescribeInstanceStatus",
            "cloudwatch:GetMetricStatistics",
            "ssm:ListCommands",
            "ssm:ListCommandInvocations",
            "ssm:DescribeInstanceInformation",
          ]
          Resource = "*"
        },
        {
          # Only effective in "apply" mode; the script never calls these in "notify" mode
          Sid      = "ResizeMoodleInstance"
          Effect   = "Allow"
          Action   = ["ec2:StopInstances", "ec2:StartInstances", "ec2:ModifyInstanceAttribute"]
          Resource = aws_instance.moodle.arn
        },
        {
          Sid      = "RunShellOnMoodleInstance"
          Effect   = "Allow"
          Action   = "ssm:SendCommand"
          Resource = [aws_instance.moodle.arn, local.ssm_run_shell_script_arn]
        },
        {
          Sid      = "PublishAlerts"
          Effect   = "Allow"
          Action   = "sns:Publish"
          Resource = aws_sns_topic.scaling_alerts.arn
        },
      ],
      var.create_rds ? [
        {
          Sid      = "ResizeMoodleDatabase"
          Effect   = "Allow"
          Action   = ["rds:DescribeDBInstances", "rds:ModifyDBInstance"]
          Resource = aws_db_instance.moodle[0].arn
        },
      ] : []
    )
  })
}

#############################################
# SSM Automation - EBS autogrow
#############################################

resource "aws_ssm_document" "ebs_autogrow" {
  name            = local.ebs_autogrow_doc_name
  document_type   = "Automation"
  document_format = "YAML"

  content = yamlencode({
    schemaVersion = "0.3"
    description   = "Grows the /moodledata EBS volume by a percentage (capped) and extends its filesystem."
    assumeRole    = "{{ AutomationAssumeRole }}"
    parameters = {
      AutomationAssumeRole = { type = "String", default = aws_iam_role.ebs_autogrow_automation.arn }
      VolumeId             = { type = "String", default = aws_ebs_volume.moodle_data.id }
      InstanceId           = { type = "String", default = aws_instance.moodle.id }
      IncrementPercent     = { type = "String", default = tostring(var.ebs_autogrow_increment_percent) }
      MaxSizeGb            = { type = "String", default = tostring(var.ebs_autogrow_max_size_gb) }
      TopicArn             = { type = "String", default = aws_sns_topic.scaling_alerts.arn }
    }
    mainSteps = [
      {
        name      = "GrowVolume"
        action    = "aws:executeScript"
        onFailure = "step:NotifyFailure"
        inputs = {
          Runtime = "python3.11"
          Handler = "handler"
          Script  = file("${path.module}/automation/ebs_autogrow.py")
          InputPayload = {
            VolumeId         = "{{ VolumeId }}"
            IncrementPercent = "{{ IncrementPercent }}"
            MaxSizeGb        = "{{ MaxSizeGb }}"
            TopicArn         = "{{ TopicArn }}"
          }
        }
        outputs = [
          { Name = "Action", Selector = "$.Payload.Action", Type = "String" },
          { Name = "Message", Selector = "$.Payload.Message", Type = "String" },
        ]
      },
      {
        name   = "CheckGrown"
        action = "aws:branch"
        inputs = {
          Choices = [
            { NextStep = "ResizeFilesystem", Variable = "{{ GrowVolume.Action }}", StringEquals = "grown" },
          ]
          Default = "Done"
        }
      },
      {
        name      = "ResizeFilesystem"
        action    = "aws:runCommand"
        onFailure = "step:NotifyFailure"
        inputs = {
          DocumentName = "AWS-RunShellScript"
          InstanceIds  = ["{{ InstanceId }}"]
          Parameters = {
            commands = ["echo ${base64encode(file("${path.module}/automation/grow_filesystem.sh"))} | base64 -d | bash"]
          }
        }
      },
      {
        name   = "NotifySuccess"
        action = "aws:executeScript"
        isEnd  = true
        inputs = {
          Runtime = "python3.11"
          Handler = "handler"
          Script  = file("${path.module}/automation/notify.py")
          InputPayload = {
            TopicArn = "{{ TopicArn }}"
            Subject  = "EBS autogrow completed"
            Message  = "{{ GrowVolume.Message }} Filesystem /moodledata extended on {{ InstanceId }}. Update data_volume_size in terraform.tfvars to match."
          }
        }
      },
      {
        name   = "NotifyFailure"
        action = "aws:executeScript"
        isEnd  = true
        inputs = {
          Runtime = "python3.11"
          Handler = "handler"
          Script  = file("${path.module}/automation/notify.py")
          InputPayload = {
            TopicArn = "{{ TopicArn }}"
            Subject  = "EBS autogrow FAILED"
            Message  = "EBS autogrow failed for volume {{ VolumeId }} on {{ InstanceId }}. Check SSM Automation execution {{ automation:EXECUTION_ID }}."
          }
        }
      },
      {
        name   = "Done"
        action = "aws:sleep"
        isEnd  = true
        inputs = { Duration = "PT1S" }
      },
    ]
  })

  tags = local.common_tags
}

#############################################
# SSM Automation - Compute autoresize
#############################################

resource "aws_ssm_document" "compute_autoresize" {
  name            = local.compute_autoresize_doc_name
  document_type   = "Automation"
  document_format = "YAML"

  content = yamlencode({
    schemaVersion = "0.3"
    description   = "Evaluates 7 days of CPU metrics and recommends (notify) or applies (apply) a one-step EC2/RDS upsize. Never downsizes."
    assumeRole    = "{{ AutomationAssumeRole }}"
    parameters = {
      AutomationAssumeRole = { type = "String", default = aws_iam_role.compute_autoresize_automation.arn }
      Mode                 = { type = "String", default = var.compute_autoresize_mode, allowedValues = ["notify", "apply"] }
      InstanceId           = { type = "String", default = aws_instance.moodle.id }
      DbInstanceIdentifier = { type = "String", default = local.rds_identifier == "" ? "none" : local.rds_identifier }
      Ec2Ladder            = { type = "StringList", default = var.ec2_instance_type_ladder }
      RdsLadder            = { type = "StringList", default = var.rds_instance_class_ladder }
      CpuThreshold         = { type = "String", default = tostring(var.cpu_high_threshold_percent) }
      CreditThreshold      = { type = "String", default = tostring(var.cpu_credit_low_threshold) }
      TopicArn             = { type = "String", default = aws_sns_topic.scaling_alerts.arn }
    }
    mainSteps = [
      {
        name      = "Evaluate"
        action    = "aws:executeScript"
        onFailure = "step:NotifyFailure"
        inputs = {
          Runtime = "python3.11"
          Handler = "handler"
          Script  = file("${path.module}/automation/compute_autoresize.py")
          InputPayload = {
            Mode                 = "{{ Mode }}"
            InstanceId           = "{{ InstanceId }}"
            DbInstanceIdentifier = "{{ DbInstanceIdentifier }}"
            Ec2Ladder            = "{{ Ec2Ladder }}"
            RdsLadder            = "{{ RdsLadder }}"
            CpuThreshold         = "{{ CpuThreshold }}"
            CreditThreshold      = "{{ CreditThreshold }}"
          }
        }
        outputs = [
          { Name = "Ec2Target", Selector = "$.Payload.Ec2Target", Type = "String" },
          { Name = "CurrentType", Selector = "$.Payload.CurrentType", Type = "String" },
          { Name = "Report", Selector = "$.Payload.Report", Type = "String" },
        ]
      },
      {
        name   = "NotifyReport"
        action = "aws:executeScript"
        inputs = {
          Runtime = "python3.11"
          Handler = "handler"
          Script  = file("${path.module}/automation/notify.py")
          InputPayload = {
            TopicArn = "{{ TopicArn }}"
            Subject  = "Moodle compute autoresize report"
            Message  = "{{ Evaluate.Report }}"
          }
        }
      },
      {
        name   = "CheckEc2Resize"
        action = "aws:branch"
        inputs = {
          Choices = [
            { NextStep = "Done", Variable = "{{ Evaluate.Ec2Target }}", StringEquals = "none" },
          ]
          Default = "StopInstance"
        }
      },
      {
        name      = "StopInstance"
        action    = "aws:changeInstanceState"
        onFailure = "step:NotifyFailure"
        inputs = {
          InstanceIds  = ["{{ InstanceId }}"]
          DesiredState = "stopped"
        }
      },
      {
        name      = "ModifyInstanceType"
        action    = "aws:executeScript"
        onFailure = "step:StartOriginalInstance"
        inputs = {
          Runtime = "python3.11"
          Handler = "handler"
          Script  = file("${path.module}/automation/modify_instance_type.py")
          InputPayload = {
            InstanceId   = "{{ InstanceId }}"
            InstanceType = "{{ Evaluate.Ec2Target }}"
          }
        }
      },
      {
        name      = "StartInstance"
        action    = "aws:changeInstanceState"
        onFailure = "step:NotifyFailure"
        inputs = {
          InstanceIds  = ["{{ InstanceId }}"]
          DesiredState = "running"
        }
      },
      {
        name           = "WaitForSsmAgent"
        action         = "aws:waitForAwsResourceProperty"
        timeoutSeconds = 600
        onFailure      = "step:NotifyFailure"
        inputs = {
          Service          = "ssm"
          Api              = "DescribeInstanceInformation"
          Filters          = [{ Key = "InstanceIds", Values = ["{{ InstanceId }}"] }]
          PropertySelector = "$.InstanceInformationList[0].PingStatus"
          DesiredValues    = ["Online"]
        }
      },
      {
        name      = "RecomputePhpFpm"
        action    = "aws:runCommand"
        onFailure = "step:NotifyFailure"
        inputs = {
          DocumentName = "AWS-RunShellScript"
          InstanceIds  = ["{{ InstanceId }}"]
          Parameters = {
            commands = ["echo ${base64encode(file("${path.module}/automation/recompute_php_fpm.sh"))} | base64 -d | bash"]
          }
        }
      },
      {
        name   = "NotifyApplied"
        action = "aws:executeScript"
        isEnd  = true
        inputs = {
          Runtime = "python3.11"
          Handler = "handler"
          Script  = file("${path.module}/automation/notify.py")
          InputPayload = {
            TopicArn = "{{ TopicArn }}"
            Subject  = "EC2 instance resized"
            Message  = "EC2 {{ InstanceId }} resized from {{ Evaluate.CurrentType }} to {{ Evaluate.Ec2Target }} (Elastic IP preserved). PHP-FPM recomputed: {{ RecomputePhpFpm.Output }} Update instance_type in terraform.tfvars to {{ Evaluate.Ec2Target }}."
          }
        }
      },
      {
        # Reached only if the type change failed: bring the instance back with its original type
        name      = "StartOriginalInstance"
        action    = "aws:changeInstanceState"
        nextStep  = "NotifyFailure"
        onFailure = "step:NotifyFailure"
        inputs = {
          InstanceIds  = ["{{ InstanceId }}"]
          DesiredState = "running"
        }
      },
      {
        name   = "NotifyFailure"
        action = "aws:executeScript"
        isEnd  = true
        inputs = {
          Runtime = "python3.11"
          Handler = "handler"
          Script  = file("${path.module}/automation/notify.py")
          InputPayload = {
            TopicArn = "{{ TopicArn }}"
            Subject  = "Compute autoresize FAILED"
            Message  = "Compute autoresize failed for {{ InstanceId }}. Verify the instance is running and check SSM Automation execution {{ automation:EXECUTION_ID }}."
          }
        }
      },
      {
        name   = "Done"
        action = "aws:sleep"
        isEnd  = true
        inputs = { Duration = "PT1S" }
      },
    ]
  })

  tags = local.common_tags
}

#############################################
# EventBridge rule - disk alarm triggers EBS autogrow
#############################################

resource "aws_iam_role" "ebs_autogrow_events" {
  count = var.enable_ebs_autogrow ? 1 : 0

  name_prefix = "${local.name_prefix}-ebs-events-"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "events.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = { StringEquals = { "aws:SourceAccount" = local.scaling_account } }
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy" "ebs_autogrow_events" {
  count = var.enable_ebs_autogrow ? 1 : 0

  name_prefix = "${local.name_prefix}-ebs-events-"
  role        = aws_iam_role.ebs_autogrow_events[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "ssm:StartAutomationExecution"
        Resource = "arn:${local.scaling_partition}:ssm:${local.scaling_region}:${local.scaling_account}:automation-definition/${aws_ssm_document.ebs_autogrow.name}:*"
      },
      {
        Effect    = "Allow"
        Action    = "iam:PassRole"
        Resource  = aws_iam_role.ebs_autogrow_automation.arn
        Condition = { StringEquals = { "iam:PassedToService" = "ssm.amazonaws.com" } }
      },
    ]
  })
}

resource "aws_cloudwatch_event_rule" "moodledata_disk_alarm" {
  count = var.enable_ebs_autogrow ? 1 : 0

  name        = "${local.name_prefix}-ebs-autogrow"
  description = "Runs EBS autogrow when the /moodledata disk alarm enters ALARM"

  event_pattern = jsonencode({
    source        = ["aws.cloudwatch"]
    "detail-type" = ["CloudWatch Alarm State Change"]
    resources     = [aws_cloudwatch_metric_alarm.moodledata_disk_high.arn]
    detail = {
      state = { value = ["ALARM"] }
    }
  })

  tags = local.common_tags
}

resource "aws_cloudwatch_event_target" "moodledata_disk_alarm" {
  count = var.enable_ebs_autogrow ? 1 : 0

  rule     = aws_cloudwatch_event_rule.moodledata_disk_alarm[0].name
  arn      = "arn:${local.scaling_partition}:ssm:${local.scaling_region}:${local.scaling_account}:automation-definition/${aws_ssm_document.ebs_autogrow.name}:$DEFAULT"
  role_arn = aws_iam_role.ebs_autogrow_events[0].arn

  # Parameter values for the automation (document defaults cover the rest)
  input = jsonencode({
    VolumeId   = [aws_ebs_volume.moodle_data.id]
    InstanceId = [aws_instance.moodle.id]
  })
}

#############################################
# EventBridge Scheduler - weekly compute autoresize
#############################################

resource "aws_iam_role" "compute_autoresize_scheduler" {
  count = var.enable_compute_autoresize ? 1 : 0

  name_prefix = "${local.name_prefix}-resize-sched-"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "scheduler.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = { StringEquals = { "aws:SourceAccount" = local.scaling_account } }
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy" "compute_autoresize_scheduler" {
  count = var.enable_compute_autoresize ? 1 : 0

  name_prefix = "${local.name_prefix}-resize-sched-"
  role        = aws_iam_role.compute_autoresize_scheduler[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "ssm:StartAutomationExecution"
        Resource = "arn:${local.scaling_partition}:ssm:${local.scaling_region}:${local.scaling_account}:automation-definition/${aws_ssm_document.compute_autoresize.name}:*"
      },
      {
        Effect    = "Allow"
        Action    = "iam:PassRole"
        Resource  = aws_iam_role.compute_autoresize_automation.arn
        Condition = { StringEquals = { "iam:PassedToService" = "ssm.amazonaws.com" } }
      },
    ]
  })
}

resource "aws_scheduler_schedule" "compute_autoresize" {
  count = var.enable_compute_autoresize ? 1 : 0

  name                         = "${local.name_prefix}-compute-autoresize"
  description                  = "Weekly compute autoresize evaluation (mode: ${var.compute_autoresize_mode})"
  schedule_expression          = var.autoresize_schedule
  schedule_expression_timezone = "UTC"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = "arn:${local.scaling_partition}:scheduler:::aws-sdk:ssm:startAutomationExecution"
    role_arn = aws_iam_role.compute_autoresize_scheduler[0].arn

    input = jsonencode({
      DocumentName = aws_ssm_document.compute_autoresize.name
      Parameters = {
        Mode = [var.compute_autoresize_mode]
      }
    })

    retry_policy {
      maximum_retry_attempts = 0
    }
  }
}
