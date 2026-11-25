# Amazon SES SMTP for Moodle 5.3 LTS outbound mail (opt-in: enable_ses_smtp = true)
#
# ############################################################################
# # WARNING - SECRETS IN TERRAFORM STATE
# # The SMTP password (aws_iam_access_key.ses_smtp_password_v4) and the IAM
# # secret key are stored in plain text in the Terraform state file.
# # Before enabling this file in production, configure the S3 backend with
# # encryption (see the commented `backend "s3"` block in main.tf: encrypt = true,
# # private bucket with versioning, restricted IAM access, DynamoDB locking).
# # Never commit terraform.tfstate* to git.
# ############################################################################
#
# Creates:
# - SES domain identity with Easy DKIM (RSA 2048) and optional custom MAIL FROM
# - Route 53 records (DKIM, optional SPF, DMARC, MAIL FROM) when route53_zone_id is set;
#   otherwise the records are exposed in the `ses_dns_records_manual` output
# - IAM user restricted to sending from *@<ses_domain>, its access key (rotated by
#   bumping ses_smtp_key_version) and the derived SMTP password
# - SSM SecureString parameters with the SMTP user/password, readable by the EC2 role
# - Configuration set (reputation metrics) publishing BOUNCE/COMPLAINT/REJECT to SNS,
#   plus CloudWatch alarms on the account-level bounce and complaint rates
# - Optional account-level suppression list (BOUNCE, COMPLAINT)
#
# Still manual: requesting SES production access (leaving the sandbox).

locals {
  ses_count   = var.enable_ses_smtp ? 1 : 0
  ses_domain  = var.ses_domain != "" ? var.ses_domain : var.domain_name
  ses_region  = data.aws_region.current.name
  ses_route53 = var.enable_ses_smtp && var.route53_zone_id != ""

  ses_mail_from_enabled = var.ses_mail_from_subdomain != ""
  ses_mail_from_domain  = local.ses_mail_from_enabled ? "${var.ses_mail_from_subdomain}.${local.ses_domain}" : ""

  ses_smtp_host        = "email-smtp.${local.ses_region}.amazonaws.com"
  ses_smtp_user_param  = var.ses_smtp_user_param != "" ? var.ses_smtp_user_param : "/${var.project_name}/${var.environment}/ses/smtp-user"
  ses_smtp_pass_param  = var.ses_smtp_pass_param != "" ? var.ses_smtp_pass_param : "/${var.project_name}/${var.environment}/ses/smtp-password"
  ses_custom_kms       = var.kms_key_id != ""
  ses_spf_value        = "v=spf1 include:amazonses.com ~all"
  ses_mail_from_mx     = "10 feedback-smtp.${local.ses_region}.amazonses.com"
  ses_dmarc_value      = join("; ", compact(["v=DMARC1", var.ses_dmarc_policy, var.ses_dmarc_rua_email != "" ? "rua=mailto:${var.ses_dmarc_rua_email}" : ""]))
  ses_config_set_name  = "${local.name_prefix}-ses"
  ses_events_topic     = "${local.name_prefix}-ses-events"
  ses_bounce_threshold = 0.05  # AWS reviews accounts at 5%, may pause sending at 10%
  ses_complaint_thresh = 0.001 # AWS reviews accounts at 0.1%, may pause sending at 0.5%

  # DNS records to create by hand when the zone is not managed in Route 53
  ses_dkim_tokens = var.enable_ses_smtp ? aws_sesv2_email_identity.moodle[0].dkim_signing_attributes[0].tokens : []
  ses_dns_records = concat(
    [for t in local.ses_dkim_tokens : { name = "${t}._domainkey.${local.ses_domain}", type = "CNAME", value = "${t}.dkim.amazonses.com" }],
    var.ses_manage_spf ? [{ name = local.ses_domain, type = "TXT", value = local.ses_spf_value }] : [],
    var.ses_dmarc_policy != "" ? [{ name = "_dmarc.${local.ses_domain}", type = "TXT", value = local.ses_dmarc_value }] : [],
    local.ses_mail_from_enabled ? [
      { name = local.ses_mail_from_domain, type = "MX", value = local.ses_mail_from_mx },
      { name = local.ses_mail_from_domain, type = "TXT", value = local.ses_spf_value },
    ] : [],
  )
}

#############################################
# SES identity, configuration set and suppression
#############################################

resource "aws_sesv2_configuration_set" "moodle" {
  count = local.ses_count

  configuration_set_name = local.ses_config_set_name

  reputation_options {
    reputation_metrics_enabled = true
  }

  tags = merge(local.common_tags, { Name = local.ses_config_set_name })
}

resource "aws_sesv2_email_identity" "moodle" {
  count = local.ses_count

  email_identity = local.ses_domain

  # Default configuration set: SMTP mail from Moodle does not send the
  # X-SES-CONFIGURATION-SET header, so events/metrics rely on this default.
  configuration_set_name = aws_sesv2_configuration_set.moodle[0].configuration_set_name

  dkim_signing_attributes {
    next_signing_key_length = "RSA_2048_BIT"
  }

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-ses-identity" })
}

resource "aws_sesv2_email_identity_mail_from_attributes" "moodle" {
  count = var.enable_ses_smtp && local.ses_mail_from_enabled ? 1 : 0

  email_identity         = aws_sesv2_email_identity.moodle[0].email_identity
  behavior_on_mx_failure = "USE_DEFAULT_VALUE"
  mail_from_domain       = local.ses_mail_from_domain
}

# NOTE: account-wide setting (affects every SES sender in this account/region),
# not only Moodle. Disable with ses_enable_account_suppression = false if another
# team manages it.
resource "aws_sesv2_account_suppression_attributes" "moodle" {
  count = var.enable_ses_smtp && var.ses_enable_account_suppression ? 1 : 0

  suppressed_reasons = ["BOUNCE", "COMPLAINT"]
}

#############################################
# SNS topic for SES events + reputation alarms
#############################################

resource "aws_sns_topic" "ses_events" {
  count = local.ses_count

  name = local.ses_events_topic

  tags = merge(local.common_tags, { Name = local.ses_events_topic })
}

resource "aws_sns_topic_policy" "ses_events" {
  count = local.ses_count

  arn = aws_sns_topic.ses_events[0].arn

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
        Resource = aws_sns_topic.ses_events[0].arn
      },
      {
        Sid       = "AllowServicePublish"
        Effect    = "Allow"
        Principal = { Service = ["ses.amazonaws.com", "cloudwatch.amazonaws.com"] }
        Action    = "sns:Publish"
        Resource  = aws_sns_topic.ses_events[0].arn
        Condition = {
          StringEquals = { "aws:SourceAccount" = local.scaling_account }
        }
      },
    ]
  })
}

resource "aws_sns_topic_subscription" "ses_events_email" {
  for_each = var.enable_ses_smtp ? toset(var.scaling_alert_emails) : toset([])

  topic_arn = aws_sns_topic.ses_events[0].arn
  protocol  = "email"
  endpoint  = each.value
}

resource "aws_sesv2_configuration_set_event_destination" "sns" {
  count = local.ses_count

  configuration_set_name = aws_sesv2_configuration_set.moodle[0].configuration_set_name
  event_destination_name = "${local.name_prefix}-ses-sns"

  event_destination {
    enabled              = true
    matching_event_types = ["BOUNCE", "COMPLAINT", "REJECT"]

    sns_destination {
      topic_arn = aws_sns_topic.ses_events[0].arn
    }
  }

  depends_on = [aws_sns_topic_policy.ses_events]
}

resource "aws_cloudwatch_metric_alarm" "ses_bounce_rate" {
  count = local.ses_count

  alarm_name          = "${local.name_prefix}-ses-bounce-rate"
  alarm_description   = "SES account bounce rate above ${local.ses_bounce_threshold * 100}% (AWS may pause sending at 10%)"
  namespace           = "AWS/SES"
  metric_name         = "Reputation.BounceRate"
  statistic           = "Maximum"
  period              = 3600
  evaluation_periods  = 1
  threshold           = local.ses_bounce_threshold
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.ses_events[0].arn]
  ok_actions          = [aws_sns_topic.ses_events[0].arn]

  tags = local.common_tags
}

resource "aws_cloudwatch_metric_alarm" "ses_complaint_rate" {
  count = local.ses_count

  alarm_name          = "${local.name_prefix}-ses-complaint-rate"
  alarm_description   = "SES account complaint rate above ${local.ses_complaint_thresh * 100}% (AWS may pause sending at 0.5%)"
  namespace           = "AWS/SES"
  metric_name         = "Reputation.ComplaintRate"
  statistic           = "Maximum"
  period              = 3600
  evaluation_periods  = 1
  threshold           = local.ses_complaint_thresh
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.ses_events[0].arn]
  ok_actions          = [aws_sns_topic.ses_events[0].arn]

  tags = local.common_tags
}

#############################################
# Route 53 records (only when route53_zone_id is set)
#############################################

resource "aws_route53_record" "ses_dkim" {
  count = local.ses_route53 ? 3 : 0

  zone_id = var.route53_zone_id
  name    = "${aws_sesv2_email_identity.moodle[0].dkim_signing_attributes[0].tokens[count.index]}._domainkey.${local.ses_domain}"
  type    = "CNAME"
  ttl     = 1800
  records = ["${aws_sesv2_email_identity.moodle[0].dkim_signing_attributes[0].tokens[count.index]}.dkim.amazonses.com"]
}

# Off by default: a root TXT record often already exists (other SPF/verification
# values). Route 53 keeps all TXT values of a name in ONE record set, so creating
# this would fail or clash; merge "include:amazonses.com" into the existing SPF instead.
resource "aws_route53_record" "ses_spf" {
  count = local.ses_route53 && var.ses_manage_spf ? 1 : 0

  zone_id = var.route53_zone_id
  name    = local.ses_domain
  type    = "TXT"
  ttl     = 3600
  records = [local.ses_spf_value]
}

resource "aws_route53_record" "ses_dmarc" {
  count = local.ses_route53 && var.ses_dmarc_policy != "" ? 1 : 0

  zone_id = var.route53_zone_id
  name    = "_dmarc.${local.ses_domain}"
  type    = "TXT"
  ttl     = 3600
  records = [local.ses_dmarc_value]
}

resource "aws_route53_record" "ses_mail_from_mx" {
  count = local.ses_route53 && local.ses_mail_from_enabled ? 1 : 0

  zone_id = var.route53_zone_id
  name    = local.ses_mail_from_domain
  type    = "MX"
  ttl     = 3600
  records = [local.ses_mail_from_mx]
}

resource "aws_route53_record" "ses_mail_from_spf" {
  count = local.ses_route53 && local.ses_mail_from_enabled ? 1 : 0

  zone_id = var.route53_zone_id
  name    = local.ses_mail_from_domain
  type    = "TXT"
  ttl     = 3600
  records = [local.ses_spf_value]
}

#############################################
# IAM user + SMTP credentials
#############################################

resource "aws_iam_user" "ses_smtp" {
  count = local.ses_count

  name = "${local.name_prefix}-ses-smtp"

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-ses-smtp" })
}

# Least privilege: send only through this identity/configuration set and only
# with a From address in the SES domain.
resource "aws_iam_user_policy" "ses_smtp" {
  count = local.ses_count

  name = "${local.name_prefix}-ses-send"
  user = aws_iam_user.ses_smtp[0].name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "SendFromDomainOnly"
        Effect = "Allow"
        Action = ["ses:SendRawEmail", "ses:SendEmail"]
        Resource = [
          aws_sesv2_email_identity.moodle[0].arn,
          aws_sesv2_configuration_set.moodle[0].arn,
        ]
        Condition = {
          StringLike = { "ses:FromAddress" = "*@${local.ses_domain}" }
        }
      },
    ]
  })
}

# Rotation: bump var.ses_smtp_key_version -> terraform apply replaces the key
# (new key created first) and updates both SSM parameters.
resource "terraform_data" "ses_smtp_key_version" {
  count = local.ses_count

  input = var.ses_smtp_key_version
}

resource "aws_iam_access_key" "ses_smtp" {
  count = local.ses_count

  user = aws_iam_user.ses_smtp[0].name

  lifecycle {
    create_before_destroy = true
    replace_triggered_by  = [terraform_data.ses_smtp_key_version[count.index]]
  }
}

resource "aws_ssm_parameter" "ses_smtp_user" {
  count = local.ses_count

  name        = local.ses_smtp_user_param
  description = "Amazon SES SMTP username (IAM access key id) for Moodle"
  type        = "SecureString"
  key_id      = local.ses_custom_kms ? var.kms_key_id : null
  value       = aws_iam_access_key.ses_smtp[0].id

  tags = local.common_tags
}

resource "aws_ssm_parameter" "ses_smtp_pass" {
  count = local.ses_count

  name        = local.ses_smtp_pass_param
  description = "Amazon SES SMTP password (SigV4-derived) for Moodle"
  type        = "SecureString"
  key_id      = local.ses_custom_kms ? var.kms_key_id : null
  value       = aws_iam_access_key.ses_smtp[0].ses_smtp_password_v4

  tags = local.common_tags
}

# EC2 role may read only these two parameters (the AWS-managed aws/ssm key needs
# no extra grant; a customer-managed key needs kms:Decrypt through SSM).
resource "aws_iam_role_policy" "ses_smtp_ssm_read" {
  count = local.ses_count

  name_prefix = "${local.name_prefix}-ses-smtp-ssm-"
  role        = aws_iam_role.moodle_ec2.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [
        {
          Sid    = "ReadSesSmtpParameters"
          Effect = "Allow"
          Action = "ssm:GetParameter"
          Resource = [
            aws_ssm_parameter.ses_smtp_user[0].arn,
            aws_ssm_parameter.ses_smtp_pass[0].arn,
          ]
        },
      ],
      local.ses_custom_kms ? [
        {
          Sid      = "DecryptSesSmtpParameters"
          Effect   = "Allow"
          Action   = "kms:Decrypt"
          Resource = var.kms_key_id
          Condition = {
            StringEquals = { "kms:ViaService" = "ssm.${local.ses_region}.amazonaws.com" }
          }
        },
      ] : [],
    )
  })
}

#############################################
# Outputs (the SMTP password is NEVER output)
#############################################

output "ses_smtp_host" {
  description = "SES SMTP endpoint (port 587, STARTTLS) -> SMTP_HOST"
  value       = var.enable_ses_smtp ? local.ses_smtp_host : null
}

output "ses_smtp_user_ssm_param" {
  description = "SSM parameter holding the SMTP username -> SMTP_USER_SSM_PARAM"
  value       = var.enable_ses_smtp ? aws_ssm_parameter.ses_smtp_user[0].name : null
}

output "ses_smtp_pass_ssm_param" {
  description = "SSM parameter holding the SMTP password -> SMTP_PASS_SSM_PARAM"
  value       = var.enable_ses_smtp ? aws_ssm_parameter.ses_smtp_pass[0].name : null
}

output "ses_noreply_address" {
  description = "Suggested Moodle no-reply sender -> NOREPLY_ADDRESS"
  value       = var.enable_ses_smtp ? "noreply@${local.ses_domain}" : null
}

output "ses_identity_status" {
  description = "SES identity verification and DKIM status (as of last apply/refresh; run `terraform refresh` after DNS propagates)"
  value = var.enable_ses_smtp ? {
    identity                    = aws_sesv2_email_identity.moodle[0].email_identity
    verified_for_sending_status = aws_sesv2_email_identity.moodle[0].verified_for_sending_status
    dkim_status                 = aws_sesv2_email_identity.moodle[0].dkim_signing_attributes[0].status
    configuration_set           = aws_sesv2_configuration_set.moodle[0].configuration_set_name
    events_topic_arn            = aws_sns_topic.ses_events[0].arn
  } : null
}

output "ses_dns_records_manual" {
  description = "DNS records to create manually (only when route53_zone_id is empty)"
  value       = var.enable_ses_smtp && var.route53_zone_id == "" ? local.ses_dns_records : null
}
