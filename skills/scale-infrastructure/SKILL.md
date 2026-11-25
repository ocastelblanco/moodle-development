---
name: scale-infrastructure
description: >-
  Diagnoses load on a running single-server Moodle deployment (EC2 + EBS + RDS) and scales it vertically, manually or via Terraform automation. Use when the site is slow, CPU/memory/disk are high, AWS credits or the free plan are a concern, or capacity must grow. Triggers: "escalar", "aumentar capacidad", "resize", "más CPU", "más disco", "free tier", "créditos AWS", "autoescalado", "scale up", "out of disk", "CPU credits".
---

# Scale Infrastructure

Ongoing operation (not a deployment phase). Scope: **single-server vertical scaling only**.

## Instructions

### 1. Diagnose first

```bash
./scripts/09-scale-infrastructure.sh --profile <profile> --region <region> report
```

Runs from the operator machine (AWS CLI v2). It prints 7/30-day EC2 CPU, CPUCreditBalance, memory and disk (CWAgent), RDS CPU/memory/storage/connections, month-to-date cost (needs `ce:GetCostAndUsage`; skipped on AccessDenied) and a recommendation. If CWAgent data is `n/a`, run `scripts/07-setup-monitoring.sh` first.

### 2. Decision table (metric -> action)

| Signal (7 days) | Action |
|-----------------|--------|
| EC2 CPU avg > 70% or CPUCreditBalance min < 50 | `resize-ec2` one step up the ladder: t4g.small > medium > large > xlarge |
| CWAgent `MEMORY_USED` > 85% sustained | `resize-ec2` one step up, then re-run `scripts/05-optimize-system.sh` (PHP-FPM `pm.max_children` depends on RAM) |
| /moodledata disk_used_percent > 80% | `grow-ebs <GB>` (~+25%); automation already does this if `enable_ebs_autogrow = true` |
| RDS CPU avg > 70% or FreeableMemory < ~150 MB | `resize-rds` one step up: db.t4g.micro > small > medium > large (default: next maintenance window; `--now` only with user approval) |
| RDS free storage low | Nothing manual: RDS storage autoscaling is already on (`max_allocated_storage`); verify the max is not reached |
| Slow static assets / high bandwidth | `enable-cloudfront-hint` (Terraform `enable_cloudfront = true`) |
| CPU fine but PHP-FPM "max_children reached" or 502/503 | Retune PHP-FPM (`scripts/05-optimize-system.sh`), do not buy hardware yet |
| Cache/session pressure on DB, DB CPU high with spare RAM | Consider Redis/Valkey for MUC and sessions (adds a service; plan it as a separate change) |

Always change ONE step at a time, then observe 24-72 h.

### 3. Apply (manual mode)

```bash
./scripts/09-scale-infrastructure.sh resize-ec2 t4g.large      # 2-5 min downtime
./scripts/09-scale-infrastructure.sh resize-rds db.t4g.medium  # maintenance window; --now = immediate
./scripts/09-scale-infrastructure.sh grow-ebs 50               # no downtime, grow only
```

Every mutating command asks for confirmation (`--yes` skips; use it only when the user already approved). Warn the user about downtime and the cost/credit impact BEFORE running. After a manual change, update `terraform/terraform.tfvars` (instance type / class / volume size) to avoid Terraform drift.

### 4. Automated mode (Terraform)

Variables (`terraform/terraform.tfvars`):

| Variable | Default | Purpose |
|----------|---------|---------|
| `enable_ebs_autogrow` | true | Disk alarm -> EventBridge -> SSM Automation grows EBS + filesystem |
| `ebs_autogrow_threshold_percent` / `_increment_percent` / `_max_size_gb` | 80 / 25 / 200 | Trigger, growth step, hard cap |
| `enable_compute_autoresize` | false | Weekly evaluation of EC2/RDS metrics |
| `compute_autoresize_mode` | "notify" | `notify` = SNS recommendation only; `apply` = climbs ONE ladder step |
| `ec2_instance_type_ladder` / `rds_instance_class_ladder` | see variables.tf | Ladders; the last item is the ceiling |
| `autoresize_schedule` | Sunday 08:00 UTC | EventBridge Scheduler cron |
| `cpu_high_threshold_percent` / `cpu_credit_low_threshold` | 70 / 50 | Thresholds |
| `scaling_alert_emails` | [] | SNS email subscribers (confirm the subscription email) |
| `monthly_budget_usd` | 30 | AWS Budgets limit (alerts 50/80/100% actual, 100% forecast) |

Enable: set the variables, `terraform apply`, and confirm the SNS subscription from each inbox. Start with `notify`; move to `apply` only after the user accepts automatic EC2 downtime (stop/modify/start; Elastic IP kept) and RDS changes in the maintenance window. Automation never scales down.

**WARNING:** after automated `apply` mode or EBS autogrow changes instance type / DB class / volume size, update `terraform.tfvars` (`instance_type`, `db_instance_class`, `data_volume_size`) BEFORE the next `terraform apply`. Otherwise Terraform reverts the change (a downsize with downtime; EBS cannot shrink, so the apply would fail). SNS messages remind the user of this. Also: `enable_cloudwatch_alarms`/`alarm_email` do NOT control the scaling alarms; those use `scaling_alert_emails`.

Reading alerts: SNS topic `<prefix>-scaling-alerts` (prefix = `<project>-<env>`) carries CloudWatch alarms (`-moodledata-disk-high`, `-ec2-cpu-high`, `-ec2-cpu-credits-low`, `-rds-cpu-high`, `-rds-freeable-memory-low`, `-rds-free-storage-low`), Budget alerts and compute-autoresize recommendations. Confirm any alert by running `report` before acting.

### 5. Free tier / credits guidance

- Since 15-Jul-2025, new AWS accounts choose **Free plan** or **Paid plan**. Credits: USD 100 on sign-up + up to USD 100 for activities (max USD 200); credits expire 12 months after account creation.
- Free plan: up to 6 months or until credits run out, only a subset of services, no charges until upgrade. Paid plan: all services, pay-as-you-go once credits are used; a monthly spend limit (from USD 20) can be set. Paid cannot go back to Free. Joining AWS Organizations ends the credits.
- NOT verified (tell the user to check the console/FAQ): exact instance types eligible in the Free plan, and what happens after 6 months without upgrading. https://aws.amazon.com/free/faqs/
- Scaling up burns credits faster: keep `monthly_budget_usd` and Budgets alerts active and report the month cost before recommending a bigger size.

### 6. Limits (be explicit with the user)

This skill only scales vertically on one server. **Horizontal scaling (ALB + EFS + Valkey + Auto Scaling Group) is a future phase, not implemented.** Orientative signals that it is time to plan it: already on t4g.xlarge / db.t4g.large with sustained CPU > 70%, roughly > 500 concurrent users, or a need for zero-downtime deploys / high availability. Say so instead of recommending an impossible vertical step.

## Troubleshooting

- `AccessDenied` on `ce get-cost-and-usage`: cost section is skipped; grant `ce:GetCostAndUsage` or read Billing console.
- Resource not found: pass `--project` / `--env` matching `project_name` / `environment` in Terraform (prefix `<project>-<env>`).
- grow-ebs filesystem step fails: instance needs SSM agent + `AmazonSSMManagedInstanceCore`; run `growpart` + `xfs_growfs /moodledata` (or `resize2fs`) manually.
- Rollback / downsize: see docs/11-scaling.md (section Rollback).
