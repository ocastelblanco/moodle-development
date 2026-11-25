# SSM Automation aws:executeScript handler (Python 3.11).
# Evaluates the last 7 days of CPU metrics for the EC2 instance and the RDS
# instance (DbInstanceIdentifier "none" = no RDS) and recommends (mode
# "notify") or applies (mode "apply") a one-step upsize along the configured
# ladders. Never downsizes; the last ladder item is the cap. EC2 changes are
# returned as "Ec2Target" ("none" = no change) for the following document
# steps (stop/modify/start); RDS changes use ApplyImmediately=False so they
# run in the RDS maintenance window.
import datetime

import boto3

HOURS = 7 * 24
BUSY_HOURS_RATIO = 0.20


def _hourly(cw, namespace, metric, dim_name, dim_value, stat):
    end = datetime.datetime.now(datetime.timezone.utc)
    start = end - datetime.timedelta(hours=HOURS)
    points = cw.get_metric_statistics(
        Namespace=namespace,
        MetricName=metric,
        Dimensions=[{"Name": dim_name, "Value": dim_value}],
        StartTime=start,
        EndTime=end,
        Period=3600,
        Statistics=[stat],
    )["Datapoints"]
    return [p[stat] for p in points]


def _assess(cw, namespace, dim_name, dim_value, cpu_threshold, credit_threshold):
    cpu = _hourly(cw, namespace, "CPUUtilization", dim_name, dim_value, "Average")
    credits = _hourly(cw, namespace, "CPUCreditBalance", dim_name, dim_value, "Minimum")
    busy = sum(1 for v in cpu if v > cpu_threshold)
    busy_ratio = busy / len(cpu) if cpu else 0.0
    min_credits = min(credits) if credits else None
    reasons = []
    if busy_ratio > BUSY_HOURS_RATIO:
        reasons.append(f"CPU > {cpu_threshold:.0f}% in {busy_ratio:.0%} of {len(cpu)} hours")
    if min_credits is not None and min_credits < credit_threshold:
        reasons.append(f"minimum CPUCreditBalance {min_credits:.1f} < {credit_threshold:.0f}")
    summary = f"hours with data={len(cpu)}, busy ratio={busy_ratio:.0%}, min credits={min_credits}"
    return reasons, summary


def _next_step(current, ladder):
    # Returns (target, note). Target is None when no upsize is possible.
    if current not in ladder:
        return None, f"current size {current} is not in the ladder {ladder}; not changing it automatically"
    idx = ladder.index(current)
    if idx >= len(ladder) - 1:
        return None, f"current size {current} is already the last ladder item (cap reached)"
    return ladder[idx + 1], ""


def handler(events, context):
    mode = events["Mode"]
    instance_id = events["InstanceId"]
    db_id = events.get("DbInstanceIdentifier", "") or ""
    if db_id == "none":
        db_id = ""
    ec2_ladder = [x for x in events["Ec2Ladder"] if x]
    rds_ladder = [x for x in events["RdsLadder"] if x]
    cpu_threshold = float(events["CpuThreshold"])
    credit_threshold = float(events["CreditThreshold"])

    cw = boto3.client("cloudwatch")
    lines = [f"Compute autoresize evaluation (mode: {mode}, window: last 7 days)"]
    ec2_target = "none"

    # EC2
    ec2 = boto3.client("ec2")
    current_type = ec2.describe_instances(InstanceIds=[instance_id])["Reservations"][0]["Instances"][0]["InstanceType"]
    reasons, summary = _assess(cw, "AWS/EC2", "InstanceId", instance_id, cpu_threshold, credit_threshold)
    lines.append(f"\nEC2 {instance_id} ({current_type}): {summary}")
    if reasons:
        target, note = _next_step(current_type, ec2_ladder)
        if target is None:
            lines.append(f"  Upsize needed ({'; '.join(reasons)}) but {note}.")
        elif mode == "apply":
            ec2_target = target
            lines.append(f"  Upsizing {current_type} -> {target} ({'; '.join(reasons)}). "
                         "The instance will be stopped and started (2-5 minutes of downtime).")
        else:
            lines.append(f"  RECOMMENDATION: upsize {current_type} -> {target} ({'; '.join(reasons)}).")
    else:
        lines.append("  No change needed.")

    # RDS (optional; create_rds may be false)
    if db_id:
        rds = boto3.client("rds")
        db = rds.describe_db_instances(DBInstanceIdentifier=db_id)["DBInstances"][0]
        current_class = db["DBInstanceClass"]
        pending_class = db.get("PendingModifiedValues", {}).get("DBInstanceClass")
        reasons, summary = _assess(cw, "AWS/RDS", "DBInstanceIdentifier", db_id, cpu_threshold, credit_threshold)
        lines.append(f"\nRDS {db_id} ({current_class}): {summary}")
        if pending_class:
            lines.append(f"  Skipped: a class change to {pending_class} is already pending.")
        elif reasons:
            target, note = _next_step(current_class, rds_ladder)
            if target is None:
                lines.append(f"  Upsize needed ({'; '.join(reasons)}) but {note}.")
            elif mode == "apply":
                rds.modify_db_instance(DBInstanceIdentifier=db_id, DBInstanceClass=target, ApplyImmediately=False)
                lines.append(f"  Scheduled {current_class} -> {target} for the next RDS maintenance window "
                             f"({db.get('PreferredMaintenanceWindow', 'n/a')} UTC).")
            else:
                lines.append(f"  RECOMMENDATION: upsize {current_class} -> {target} ({'; '.join(reasons)}).")
        else:
            lines.append("  No change needed.")
    else:
        lines.append("\nRDS: not managed by this stack (create_rds = false); skipped.")

    if mode == "apply":
        lines.append("\nIMPORTANT: update instance_type / db_instance_class in terraform.tfvars to the new "
                     "sizes, otherwise the next 'terraform apply' will try to revert them.")
    return {"Ec2Target": ec2_target, "CurrentType": current_type, "Report": "\n".join(lines)}
