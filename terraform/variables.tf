# Variables for Moodle 5.3 LTS AWS Infrastructure
# Configure these values before running terraform apply
#
# NOTE: Moodle 5.3 LTS requirements:
# - PHP 8.3+ (8.4 used on Amazon Linux 2023; 8.5 not supported)
# - Apache DocumentRoot must point to /var/www/html/moodle/public (not /var/www/html/moodle)
# - MariaDB 11.4+ (RDS 11.8 used), MySQL 8.4+, or PostgreSQL 15+

#############################################
# General Configuration
#############################################

variable "project_name" {
  description = "Project name for resource naming"
  type        = string
  default     = "moodle"
}

variable "environment" {
  description = "Environment name (dev, staging, prod)"
  type        = string
  default     = "prod"
}

variable "aws_region" {
  description = "AWS region for resources"
  type        = string
  default     = "us-east-1"
}

variable "aws_profile" {
  description = "AWS CLI profile to use"
  type        = string
  default     = "default"
}

variable "tags" {
  description = "Common tags to apply to all resources"
  type        = map(string)
  default = {
    Project     = "Moodle 5.3 LTS"
    ManagedBy   = "Terraform"
    Environment = "Production"
  }
}

#############################################
# Network Configuration
#############################################

variable "vpc_id" {
  description = "VPC ID (leave empty to use default VPC)"
  type        = string
  default     = ""
}

variable "subnet_id" {
  description = "Subnet ID for EC2 instance (leave empty to use default)"
  type        = string
  default     = ""
}

variable "allowed_ssh_cidrs" {
  description = "List of CIDR blocks allowed to SSH"
  type        = list(string)
  default     = ["0.0.0.0/0"] # CHANGE THIS to your IP!
}

#############################################
# EC2 Instance Configuration
#############################################

variable "instance_type" {
  description = "EC2 instance type (t4g.medium recommended for 100-300 users)"
  type        = string
  default     = "t4g.medium"

  validation {
    condition     = can(regex("^t4g\\.", var.instance_type))
    error_message = "Use ARM-based t4g instances for cost optimization."
  }
}

variable "ami_id" {
  description = "AMI ID for Amazon Linux 2023 ARM64 (leave empty for auto-lookup)"
  type        = string
  default     = ""
}

variable "key_pair_name" {
  description = "Name of existing EC2 key pair for SSH access"
  type        = string
}

variable "root_volume_size" {
  description = "Size of root EBS volume in GB"
  type        = number
  default     = 15
}

variable "data_volume_size" {
  description = "Size of data EBS volume for Moodle data (/moodledata) in GB"
  type        = number
  default     = 25
}

variable "ebs_volume_type" {
  description = "EBS volume type (gp3 recommended)"
  type        = string
  default     = "gp3"
}

variable "ebs_iops" {
  description = "IOPS for gp3 volumes (3000-16000)"
  type        = number
  default     = 3000
}

variable "ebs_throughput" {
  description = "Throughput for gp3 volumes in MB/s (125-1000)"
  type        = number
  default     = 125
}

variable "enable_detailed_monitoring" {
  description = "Enable detailed CloudWatch monitoring (additional cost)"
  type        = bool
  default     = false
}

#############################################
# RDS Configuration
#############################################

variable "create_rds" {
  description = "Whether to create RDS instance"
  type        = bool
  default     = true
}

variable "db_instance_class" {
  description = "RDS instance class (db.t4g.micro for < 500 users)"
  type        = string
  default     = "db.t4g.micro"
}

variable "db_engine_version" {
  description = "MariaDB major version (minor upgrades automatic; Moodle 5.3 needs >= 11.4)"
  type        = string
  default     = "11.8"
}

variable "db_allocated_storage" {
  description = "Initial storage size in GB"
  type        = number
  default     = 20
}

variable "db_max_allocated_storage" {
  description = "Maximum storage size for autoscaling in GB"
  type        = number
  default     = 100
}

variable "db_name" {
  description = "Database name for Moodle"
  type        = string
  default     = "moodle"
}

variable "db_username" {
  description = "Master username for database"
  type        = string
  default     = "moodleadmin"
  sensitive   = true
}

variable "db_password" {
  description = "Master password for database (min 8 chars)"
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.db_password) >= 8
    error_message = "Database password must be at least 8 characters long."
  }
}

variable "db_backup_retention_period" {
  description = "Days to retain automated backups (0-35)"
  type        = number
  default     = 7
}

variable "db_backup_window" {
  description = "Daily backup window (UTC)"
  type        = string
  default     = "03:00-04:00"
}

variable "db_maintenance_window" {
  description = "Weekly maintenance window (UTC)"
  type        = string
  default     = "sun:04:00-sun:05:00"
}

variable "db_multi_az" {
  description = "Enable Multi-AZ deployment for high availability"
  type        = bool
  default     = false
}

variable "db_publicly_accessible" {
  description = "Make RDS publicly accessible (NOT recommended)"
  type        = bool
  default     = false
}

#############################################
# Domain & SSL Configuration
#############################################

variable "domain_name" {
  description = "Domain name for Moodle (e.g., moodle.example.com)"
  type        = string
}

variable "admin_email" {
  description = "Admin email for Let's Encrypt notifications"
  type        = string
}

variable "create_route53_record" {
  description = "Create Route 53 A record for domain"
  type        = bool
  default     = false
}

variable "route53_zone_id" {
  description = "Route 53 hosted zone ID (if create_route53_record is true)"
  type        = string
  default     = ""
}

#############################################
# CloudFront CDN Configuration
#############################################

variable "enable_cloudfront" {
  description = "Enable CloudFront CDN for static assets"
  type        = bool
  default     = false
}

variable "cloudfront_price_class" {
  description = "CloudFront price class (PriceClass_100, PriceClass_200, PriceClass_All)"
  type        = string
  default     = "PriceClass_100" # US, Canada, Europe
}

#############################################
# Monitoring & Alerting
#############################################

variable "enable_cloudwatch_alarms" {
  description = "Create CloudWatch alarms for monitoring"
  type        = bool
  default     = true
}

variable "alarm_email" {
  description = "Email address for alarm notifications"
  type        = string
  default     = ""
}

variable "cpu_alarm_threshold" {
  description = "CPU utilization threshold for alarm (%)"
  type        = number
  default     = 80
}

variable "memory_alarm_threshold" {
  description = "Available memory threshold for alarm (MB)"
  type        = number
  default     = 500
}

variable "disk_alarm_threshold" {
  description = "Disk usage threshold for alarm (%)"
  type        = number
  default     = 80
}

#############################################
# Backup Configuration
#############################################

variable "enable_ebs_snapshots" {
  description = "Enable automated EBS snapshots"
  type        = bool
  default     = true
}

variable "snapshot_retention_days" {
  description = "Days to retain EBS snapshots"
  type        = number
  default     = 7
}

variable "snapshot_schedule" {
  description = "Cron expression for snapshot schedule (UTC)"
  type        = string
  default     = "cron(0 2 * * ? *)" # Daily at 2 AM UTC
}

#############################################
# Optimization Settings
#############################################

variable "php_fpm_max_children" {
  description = "PHP-FPM max_children (0 for auto-calculate based on RAM)"
  type        = number
  default     = 0
}

variable "enable_swap" {
  description = "Configure SWAP space"
  type        = bool
  default     = true
}

variable "swap_size_gb" {
  description = "SWAP size in GB (0 for auto-calculate based on RAM)"
  type        = number
  default     = 0
}

#############################################
# Moodle Configuration
#############################################

variable "moodle_version" {
  description = "Moodle version to install (branch name)"
  type        = string
  default     = "MOODLE_503_STABLE"
}

variable "moodle_admin_user" {
  description = "Moodle admin username"
  type        = string
  default     = "admin"
}

variable "moodle_admin_password" {
  description = "Moodle admin password (min 8 chars, use strong password)"
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.moodle_admin_password) >= 8
    error_message = "Moodle admin password must be at least 8 characters long."
  }
}

variable "moodle_site_name" {
  description = "Moodle site name"
  type        = string
  default     = "My Moodle Site"
}

variable "moodle_site_summary" {
  description = "Moodle site summary/description"
  type        = string
  default     = "Learning Management System"
}

#############################################
# Scaling, Autoresize & Cost Control
#############################################

variable "enable_ebs_autogrow" {
  description = "Automatically grow the /moodledata EBS volume when the disk alarm fires"
  type        = bool
  default     = true
}

variable "ebs_autogrow_threshold_percent" {
  description = "Disk usage (%) of /moodledata that triggers the alarm and EBS autogrow"
  type        = number
  default     = 80

  validation {
    condition     = var.ebs_autogrow_threshold_percent > 0 && var.ebs_autogrow_threshold_percent < 100
    error_message = "ebs_autogrow_threshold_percent must be between 1 and 99."
  }
}

variable "ebs_autogrow_increment_percent" {
  description = "Percentage by which the /moodledata volume grows on each autogrow run"
  type        = number
  default     = 25

  validation {
    condition     = var.ebs_autogrow_increment_percent >= 1 && var.ebs_autogrow_increment_percent <= 100
    error_message = "ebs_autogrow_increment_percent must be between 1 and 100."
  }
}

variable "ebs_autogrow_max_size_gb" {
  description = "Maximum size (GB) EBS autogrow may reach for /moodledata"
  type        = number
  default     = 200

  validation {
    condition     = var.ebs_autogrow_max_size_gb >= 1 && var.ebs_autogrow_max_size_gb <= 16384
    error_message = "ebs_autogrow_max_size_gb must be between 1 and 16384 (gp3 limit)."
  }
}

variable "enable_compute_autoresize" {
  description = "Schedule the weekly compute autoresize evaluation (EC2 + RDS)"
  type        = bool
  default     = false
}

variable "compute_autoresize_mode" {
  description = "notify = only publish a recommendation to SNS; apply = upsize one ladder step (EC2 stop/start, RDS in maintenance window)"
  type        = string
  default     = "notify"

  validation {
    condition     = contains(["notify", "apply"], var.compute_autoresize_mode)
    error_message = "compute_autoresize_mode must be \"notify\" or \"apply\"."
  }
}

variable "ec2_instance_type_ladder" {
  description = "Ordered EC2 instance types (smallest to largest) used by compute autoresize; the last item is the cap"
  type        = list(string)
  default     = ["t4g.small", "t4g.medium", "t4g.large", "t4g.xlarge"]

  validation {
    condition     = length(var.ec2_instance_type_ladder) > 0 && alltrue([for t in var.ec2_instance_type_ladder : can(regex("^[a-z0-9-]+\\.[a-z0-9]+$", t))])
    error_message = "ec2_instance_type_ladder must be a non-empty list of valid instance types (e.g. t4g.medium)."
  }
}

variable "rds_instance_class_ladder" {
  description = "Ordered RDS instance classes (smallest to largest) used by compute autoresize; the last item is the cap"
  type        = list(string)
  default     = ["db.t4g.micro", "db.t4g.small", "db.t4g.medium", "db.t4g.large"]

  validation {
    condition     = length(var.rds_instance_class_ladder) > 0 && alltrue([for c in var.rds_instance_class_ladder : can(regex("^db\\.[a-z0-9-]+\\.[a-z0-9]+$", c))])
    error_message = "rds_instance_class_ladder must be a non-empty list of valid RDS classes (e.g. db.t4g.micro)."
  }
}

variable "autoresize_schedule" {
  description = "EventBridge Scheduler expression (UTC) for the compute autoresize evaluation"
  type        = string
  default     = "cron(0 8 ? * SUN *)" # Sunday 03:00 Colombia time (UTC-5)

  validation {
    condition     = can(regex("^(cron|rate)\\(.+\\)$", var.autoresize_schedule))
    error_message = "autoresize_schedule must be a cron(...) or rate(...) expression."
  }
}

variable "cpu_high_threshold_percent" {
  description = "Average CPU (%) considered high for alarms and autoresize evaluation"
  type        = number
  default     = 70

  validation {
    condition     = var.cpu_high_threshold_percent > 0 && var.cpu_high_threshold_percent <= 100
    error_message = "cpu_high_threshold_percent must be between 1 and 100."
  }
}

variable "cpu_credit_low_threshold" {
  description = "CPUCreditBalance below which burstable instances are considered starved"
  type        = number
  default     = 50

  validation {
    condition     = var.cpu_credit_low_threshold >= 0
    error_message = "cpu_credit_low_threshold must be >= 0."
  }
}

variable "scaling_alert_emails" {
  description = "Emails subscribed to the scaling alerts SNS topic and budget notifications (empty = no subscriptions)"
  type        = list(string)
  default     = []

  validation {
    condition     = length(var.scaling_alert_emails) <= 10 && alltrue([for e in var.scaling_alert_emails : can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", e))])
    error_message = "scaling_alert_emails must contain at most 10 valid email addresses."
  }
}

variable "monthly_budget_usd" {
  description = "Monthly AWS cost budget in USD (alerts at 50/80/100% actual and 100% forecast)"
  type        = number
  default     = 30

  validation {
    condition     = var.monthly_budget_usd > 0
    error_message = "monthly_budget_usd must be greater than 0."
  }
}

#############################################
# SES SMTP (ses.tf)
#############################################

variable "enable_ses_smtp" {
  description = "Create SES identity, SMTP IAM user/credentials (in SSM) and monitoring for Moodle mail. The SMTP password ends up in Terraform state: use the encrypted S3 backend."
  type        = bool
  default     = false
}

variable "ses_domain" {
  description = "Domain verified in SES for sending (empty = domain_name)"
  type        = string
  default     = ""
}

variable "ses_mail_from_subdomain" {
  description = "Custom MAIL FROM subdomain label (e.g. \"mail\" -> mail.<ses_domain>); empty = use amazonses.com"
  type        = string
  default     = ""

  validation {
    condition     = can(regex("^([a-z0-9]([a-z0-9-]*[a-z0-9])?)?$", var.ses_mail_from_subdomain))
    error_message = "ses_mail_from_subdomain must be a single DNS label (e.g. \"mail\") or empty."
  }
}

variable "ses_manage_spf" {
  description = "Create the root SPF TXT record in Route 53. Default false: a root TXT record often already exists and Route 53 keeps one TXT record set per name; merge include:amazonses.com manually in that case"
  type        = bool
  default     = false
}

variable "ses_dmarc_policy" {
  description = "DMARC policy tag for _dmarc.<ses_domain> (e.g. \"p=quarantine\"); empty = do not manage DMARC"
  type        = string
  default     = "p=quarantine"

  validation {
    condition     = can(regex("^(p=(none|quarantine|reject).*)?$", var.ses_dmarc_policy))
    error_message = "ses_dmarc_policy must be empty or start with p=none|p=quarantine|p=reject."
  }
}

variable "ses_dmarc_rua_email" {
  description = "Mailbox for DMARC aggregate reports (rua); empty = no rua tag"
  type        = string
  default     = ""
}

variable "ses_smtp_key_version" {
  description = "Bump (e.g. \"1\" -> \"2\") to rotate the SES SMTP access key and update the SSM parameters"
  type        = string
  default     = "1"
}

variable "ses_smtp_user_param" {
  description = "SSM parameter name for the SMTP username (empty = /<project_name>/<environment>/ses/smtp-user)"
  type        = string
  default     = ""
}

variable "ses_smtp_pass_param" {
  description = "SSM parameter name for the SMTP password (empty = /<project_name>/<environment>/ses/smtp-password)"
  type        = string
  default     = ""
}

variable "kms_key_id" {
  description = "Customer-managed KMS key ARN for the SES SMTP SSM parameters (empty = AWS-managed aws/ssm key)"
  type        = string
  default     = ""

  validation {
    condition     = var.kms_key_id == "" || can(regex("^arn:", var.kms_key_id))
    error_message = "kms_key_id must be empty or a KMS key ARN (needed for the EC2 role kms:Decrypt grant)."
  }
}

variable "ses_enable_account_suppression" {
  description = "Enable the SES ACCOUNT-LEVEL suppression list for BOUNCE and COMPLAINT (affects every sender in this account/region)"
  type        = bool
  default     = true
}
