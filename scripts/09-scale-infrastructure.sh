#!/bin/bash
# shellcheck disable=SC2016  # remote commands are intentionally single-quoted
#############################################
# 09-scale-infrastructure.sh
# Manual, AI-assisted scaling CLI for the Moodle single-server stack.
# Runs from the OPERATOR'S MACHINE (AWS CLI v2 + configured profile), not on the EC2 instance.
#
# Subcommands:
#   report                      Collect metrics (7/30 days) and print a recommendation
#   resize-ec2 <type>           Change EC2 instance type (stop -> modify -> start)
#   resize-rds <class> [--now]  Change RDS instance class (maintenance window unless --now)
#   grow-ebs <GB>               Grow the /moodledata EBS volume and its filesystem
#   enable-cloudfront-hint      Print how to enable CloudFront (Terraform)
#############################################

set -euo pipefail

#############################################
# Defaults (override via env or flags)
#############################################
PROFILE="${AWS_PROFILE:-}"
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"
PROJECT="${PROJECT_NAME:-moodle}"
ENVIRONMENT_NAME="${ENVIRONMENT:-prod}"
ASSUME_YES="false"
RDS_NOW="false"

# Recommendation thresholds (same as Terraform defaults)
CPU_HIGH=70            # avg CPU % considered high
CREDITS_LOW=50         # CPUCreditBalance minimum considered low
MEM_HIGH=85            # CWAgent MEMORY_USED (renamed mem_used_percent) considered high
DISK_HIGH=80           # disk_used_percent considered high
RDS_MEM_LOW_MB=150     # RDS FreeableMemory (MB) considered low
RDS_STORAGE_LOW_GB=3   # RDS FreeStorageSpace (GB) considered low

usage() {
    cat <<'EOF'
Usage: 09-scale-infrastructure.sh [global options] <command> [args]

Commands:
  report                       Metrics (7/30 days) for EC2, EBS, RDS + month cost + recommendation
  resize-ec2 <type>            e.g. t4g.large  (2-5 min downtime; Elastic IP is kept)
  resize-rds <class> [--now]   e.g. db.t4g.medium (applied in maintenance window unless --now)
  grow-ebs <GB>                New total size of the /moodledata volume (grow only)
  enable-cloudfront-hint       Show how to enable the CloudFront CDN

Global options:
  --profile <name>      AWS profile (default: $AWS_PROFILE)
  --region <region>     AWS region (default: $AWS_REGION or us-east-1)
  --project <name>      Project name used in resource names (default: $PROJECT_NAME or moodle)
  --env <name>          Environment (default: $ENVIRONMENT or prod)
  --yes                 Skip confirmation prompts
  -h, --help            Show this help

Resources are discovered by name prefix: <project>-<env>-* (tag Name=<prefix>-ec2,
<prefix>-data, RDS identifier prefix <prefix>-db-). Terraform remains the source of truth:
after a manual resize, update terraform.tfvars to avoid drift.
EOF
}

#############################################
# Helpers
#############################################
log()  { echo "[INFO] $*"; }
warn() { echo "[WARN] $*" >&2; }
die()  { echo "[ERROR] $*" >&2; exit 1; }

aws_cmd() {
    if [ -n "$PROFILE" ]; then
        aws --profile "$PROFILE" --region "$REGION" "$@"
    else
        aws --region "$REGION" "$@"
    fi
}

confirm() {
    [ "$ASSUME_YES" = "true" ] && return 0
    local answer
    read -r -p "$1 [y/N] " answer
    case "$answer" in y|Y|yes|YES) return 0 ;; *) die "Aborted by user." ;; esac
}

PREFIX=""
INSTANCE_ID=""
VOLUME_ID=""
DB_ID=""

discover() {
    command -v aws >/dev/null 2>&1 || die "AWS CLI not found"
    aws_cmd sts get-caller-identity >/dev/null 2>&1 || die "AWS credentials not valid (check --profile/--region)"
    PREFIX="${PROJECT}-${ENVIRONMENT_NAME}"

    INSTANCE_ID=$(aws_cmd ec2 describe-instances \
        --filters "Name=tag:Name,Values=${PREFIX}-ec2" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
        --query 'Reservations[0].Instances[0].InstanceId' --output text 2>/dev/null || true)
    [ -z "$INSTANCE_ID" ] || [ "$INSTANCE_ID" = "None" ] && die "EC2 instance with tag Name=${PREFIX}-ec2 not found"

    VOLUME_ID=$(aws_cmd ec2 describe-volumes \
        --filters "Name=tag:Name,Values=${PREFIX}-data" \
        --query 'Volumes[0].VolumeId' --output text 2>/dev/null || true)
    [ "$VOLUME_ID" = "None" ] && VOLUME_ID=""

    DB_ID=$(aws_cmd rds describe-db-instances \
        --query "DBInstances[?starts_with(DBInstanceIdentifier, \`${PREFIX}-db-\`)].DBInstanceIdentifier | [0]" \
        --output text 2>/dev/null || true)
    [ "$DB_ID" = "None" ] && DB_ID=""

    log "Region: $REGION | EC2: $INSTANCE_ID | EBS data: ${VOLUME_ID:-n/a} | RDS: ${DB_ID:-n/a}"
}

# metric <namespace> <metric> <stat> <days> <dim args...> -> prints a single number or "n/a"
metric() {
    local ns="$1" name="$2" stat="$3" days="$4"; shift 4
    local start end period=3600 raw
    start=$(date -u -v-"${days}"d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "-${days} days" +%Y-%m-%dT%H:%M:%SZ)
    end=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    # Use hourly datapoints and aggregate client-side to stay under the 1440 datapoint limit
    case "$stat" in
        Average) local q="avg" ;;
        Maximum) local q="max" ;;
        Minimum) local q="min" ;;
        *) die "bad stat $stat" ;;
    esac
    raw=$(aws_cmd cloudwatch get-metric-statistics --namespace "$ns" --metric-name "$name" \
        --start-time "$start" --end-time "$end" --period "$period" --statistics "$stat" \
        --dimensions "$@" --query "Datapoints[].${stat}" --output text 2>/dev/null || true)
    if [ -z "$raw" ] || [ "$raw" = "None" ]; then echo "n/a"; return; fi
    echo "$raw" | tr '\t' '\n' | awk -v q="$q" '
        NR==1 {min=$1; max=$1}
        {s+=$1; n++; if($1<min)min=$1; if($1>max)max=$1}
        END {if(n==0){print "n/a"} else if(q=="avg") printf "%.1f\n", s/n; else if(q=="max") printf "%.1f\n", max; else printf "%.1f\n", min}'
}

# gt <a> <b> -> true when a > b and a is numeric
gt() { [ "$1" != "n/a" ] && awk -v a="$1" -v b="$2" 'BEGIN{exit !(a>b)}'; }
lt() { [ "$1" != "n/a" ] && awk -v a="$1" -v b="$2" 'BEGIN{exit !(a<b)}'; }

#############################################
# report
#############################################
cmd_report() {
    discover
    local itype dbclass dbstorage vsize
    itype=$(aws_cmd ec2 describe-instances --instance-ids "$INSTANCE_ID" --query 'Reservations[0].Instances[0].InstanceType' --output text)
    echo
    echo "=== EC2 ($INSTANCE_ID, $itype) ==="
    local d
    for d in 7 30; do
        echo "  ${d}d CPU avg/max (%):  $(metric AWS/EC2 CPUUtilization Average $d Name=InstanceId,Value="$INSTANCE_ID") / $(metric AWS/EC2 CPUUtilization Maximum $d Name=InstanceId,Value="$INSTANCE_ID")"
        echo "  ${d}d CPUCreditBalance min: $(metric AWS/EC2 CPUCreditBalance Minimum $d Name=InstanceId,Value="$INSTANCE_ID")"
    done
    local mem7 disk7 diskroot7
    mem7=$(metric CWAgent MEMORY_USED Maximum 7 Name=InstanceId,Value="$INSTANCE_ID")
    disk7=$(metric CWAgent disk_used_percent Maximum 7 Name=InstanceId,Value="$INSTANCE_ID" Name=path,Value=/moodledata)
    diskroot7=$(metric CWAgent disk_used_percent Maximum 7 Name=InstanceId,Value="$INSTANCE_ID" Name=path,Value=/)
    echo "  7d MEMORY_USED max: $mem7   (30d max: $(metric CWAgent MEMORY_USED Maximum 30 Name=InstanceId,Value="$INSTANCE_ID"))"
    echo "  7d disk_used_percent max  /moodledata: $disk7   /: $diskroot7"
    [ "$mem7" = "n/a" ] && warn "No CWAgent data: run scripts/07-setup-monitoring.sh to publish memory/disk metrics"

    if [ -n "$VOLUME_ID" ]; then
        vsize=$(aws_cmd ec2 describe-volumes --volume-ids "$VOLUME_ID" --query 'Volumes[0].Size' --output text)
        echo "  EBS data volume: $VOLUME_ID (${vsize} GB)"
    fi

    local rcpu7="n/a" rmem7="n/a" rfree7="n/a"
    if [ -n "$DB_ID" ]; then
        dbclass=$(aws_cmd rds describe-db-instances --db-instance-identifier "$DB_ID" --query 'DBInstances[0].DBInstanceClass' --output text)
        dbstorage=$(aws_cmd rds describe-db-instances --db-instance-identifier "$DB_ID" \
            --query 'DBInstances[0].[AllocatedStorage,MaxAllocatedStorage]' --output text)
        echo
        echo "=== RDS ($DB_ID, $dbclass; storage GB allocated/max: $dbstorage) ==="
        for d in 7 30; do
            echo "  ${d}d CPU avg/max (%): $(metric AWS/RDS CPUUtilization Average $d Name=DBInstanceIdentifier,Value="$DB_ID") / $(metric AWS/RDS CPUUtilization Maximum $d Name=DBInstanceIdentifier,Value="$DB_ID")"
            echo "  ${d}d FreeableMemory min (bytes): $(metric AWS/RDS FreeableMemory Minimum $d Name=DBInstanceIdentifier,Value="$DB_ID")"
            echo "  ${d}d FreeStorageSpace min (bytes): $(metric AWS/RDS FreeStorageSpace Minimum $d Name=DBInstanceIdentifier,Value="$DB_ID")"
            echo "  ${d}d DatabaseConnections max: $(metric AWS/RDS DatabaseConnections Maximum $d Name=DBInstanceIdentifier,Value="$DB_ID")"
        done
        rcpu7=$(metric AWS/RDS CPUUtilization Average 7 Name=DBInstanceIdentifier,Value="$DB_ID")
        rmem7=$(metric AWS/RDS FreeableMemory Minimum 7 Name=DBInstanceIdentifier,Value="$DB_ID")
        rfree7=$(metric AWS/RDS FreeStorageSpace Minimum 7 Name=DBInstanceIdentifier,Value="$DB_ID")
    fi

    echo
    echo "=== Cost (current month, UnblendedCost) ==="
    local cstart cend cost
    cstart=$(date -u +%Y-%m-01)
    cend=$(date -u -v+1d +%Y-%m-%d 2>/dev/null || date -u -d "+1 day" +%Y-%m-%d)
    # Cost Explorer is served from us-east-1
    if cost=$(aws_cmd --region us-east-1 ce get-cost-and-usage --time-period "Start=${cstart},End=${cend}" \
        --granularity MONTHLY --metrics UnblendedCost \
        --query 'ResultsByTime[0].Total.UnblendedCost.[Amount,Unit]' --output text 2>/dev/null); then
        echo "  $cost  (note: credits are applied separately; check Billing console for net amount)"
    else
        warn "Cost Explorer not available (AccessDenied or not enabled); skipping cost"
    fi

    echo
    echo "=== Recommendation ==="
    local cpu7 cmin7 recs=0
    cpu7=$(metric AWS/EC2 CPUUtilization Average 7 Name=InstanceId,Value="$INSTANCE_ID")
    cmin7=$(metric AWS/EC2 CPUCreditBalance Minimum 7 Name=InstanceId,Value="$INSTANCE_ID")
    if gt "$cpu7" "$CPU_HIGH" || lt "$cmin7" "$CREDITS_LOW"; then
        echo "  - EC2: CPU avg > ${CPU_HIGH}% or credits < ${CREDITS_LOW}: resize-ec2 one step up (t4g.small>medium>large>xlarge)"; recs=1
    fi
    if gt "$mem7" "$MEM_HIGH"; then
        echo "  - EC2: memory > ${MEM_HIGH}%: resize-ec2 one step up, then re-run 05-optimize-system.sh"; recs=1
    fi
    if gt "$disk7" "$DISK_HIGH"; then
        echo "  - EBS: /moodledata > ${DISK_HIGH}%: grow-ebs (~+25%)"; recs=1
    fi
    if gt "$diskroot7" "$DISK_HIGH"; then
        echo "  - EBS: root / > ${DISK_HIGH}%: clean logs/cache or grow root volume"; recs=1
    fi
    if gt "$rcpu7" "$CPU_HIGH"; then
        echo "  - RDS: CPU avg > ${CPU_HIGH}%: resize-rds one step up (db.t4g.micro>small>medium>large)"; recs=1
    fi
    if [ "$rmem7" != "n/a" ] && awk -v a="$rmem7" -v b="$RDS_MEM_LOW_MB" 'BEGIN{exit !(a/1048576<b)}'; then
        echo "  - RDS: FreeableMemory < ${RDS_MEM_LOW_MB} MB: resize-rds one step up"; recs=1
    fi
    if [ "$rfree7" != "n/a" ] && awk -v a="$rfree7" -v b="$RDS_STORAGE_LOW_GB" 'BEGIN{exit !(a/1073741824<b)}'; then
        echo "  - RDS: free storage < ${RDS_STORAGE_LOW_GB} GB: storage autoscaling should grow it; verify max_allocated_storage"; recs=1
    fi
    [ "$recs" -eq 0 ] && echo "  No scaling needed: all metrics within thresholds (or no data yet)."
    echo "  Reminder: at t4g.xlarge with sustained CPU > ${CPU_HIGH}%, vertical scaling is exhausted (see docs/11-scaling.md)."
}

#############################################
# resize-ec2
#############################################
cmd_resize_ec2() {
    local target="${1:-}"
    [ -z "$target" ] && die "Usage: resize-ec2 <instance-type>"
    discover
    local current
    current=$(aws_cmd ec2 describe-instances --instance-ids "$INSTANCE_ID" --query 'Reservations[0].Instances[0].InstanceType' --output text)
    [ "$current" = "$target" ] && die "Instance is already $target"
    case "$target" in t4g.*|m6g.*|c6g.*) ;; *) die "Only Graviton (ARM64) types are supported (t4g/m6g/c6g): AMI is arm64" ;; esac

    warn "EC2 $INSTANCE_ID: $current -> $target. Site will be DOWN for ~2-5 minutes (stop/modify/start)."
    warn "Bigger instances consume AWS credits / increase monthly cost. Elastic IP is preserved."
    confirm "Proceed with EC2 resize?"

    log "Stopping instance..."
    aws_cmd ec2 stop-instances --instance-ids "$INSTANCE_ID" >/dev/null
    aws_cmd ec2 wait instance-stopped --instance-ids "$INSTANCE_ID"
    log "Modifying instance type..."
    aws_cmd ec2 modify-instance-attribute --instance-id "$INSTANCE_ID" --instance-type "{\"Value\": \"$target\"}"
    log "Starting instance..."
    aws_cmd ec2 start-instances --instance-ids "$INSTANCE_ID" >/dev/null
    aws_cmd ec2 wait instance-running --instance-ids "$INSTANCE_ID"
    aws_cmd ec2 wait instance-status-ok --instance-ids "$INSTANCE_ID"
    log "Instance is running as $target."

    echo
    log "PHP-FPM and system tuning depend on RAM: re-run scripts/05-optimize-system.sh on the instance."
    if confirm_optional "Run it now via SSM Run Command (if script exists on the instance)?"; then
        run_ssm 'for p in /opt/moodle-scripts/05-optimize-system.sh /root/05-optimize-system.sh /home/ec2-user/05-optimize-system.sh; do if [ -f "$p" ]; then bash "$p" && exit 0; fi; done; echo "05-optimize-system.sh not found on instance"; exit 1'
    fi
    log "Update instance_type in terraform/terraform.tfvars to match $target (avoid Terraform drift)."
}

# Like confirm but returns 1 instead of aborting (and false under --yes only if not interactive)
confirm_optional() {
    [ "$ASSUME_YES" = "true" ] && return 0
    local answer
    read -r -p "$1 [y/N] " answer
    case "$answer" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

# shellcheck disable=SC2016  # remote commands are intentionally single-quoted
# run_ssm <shell command> : send command through SSM and wait
run_ssm() {
    local cmd_id status b64
    # base64 avoids JSON/shell quoting problems with the remote command
    b64=$(printf '%s' "$1" | base64 | tr -d '\n')
    cmd_id=$(aws_cmd ssm send-command --instance-ids "$INSTANCE_ID" --document-name AWS-RunShellScript \
        --parameters "commands=[\"echo $b64 | base64 -d | bash\"]" --query 'Command.CommandId' --output text) \
        || { warn "SSM send-command failed (is the SSM agent / instance profile configured?)"; return 1; }
    aws_cmd ssm wait command-executed --command-id "$cmd_id" --instance-id "$INSTANCE_ID" 2>/dev/null || true
    status=$(aws_cmd ssm get-command-invocation --command-id "$cmd_id" --instance-id "$INSTANCE_ID" --query 'Status' --output text)
    aws_cmd ssm get-command-invocation --command-id "$cmd_id" --instance-id "$INSTANCE_ID" \
        --query 'StandardOutputContent' --output text | tail -n 20
    [ "$status" = "Success" ] || { warn "SSM command finished with status: $status"; return 1; }
}

#############################################
# resize-rds
#############################################
cmd_resize_rds() {
    local target="${1:-}"
    [ -z "$target" ] && die "Usage: resize-rds <db-instance-class> [--now]"
    discover
    [ -z "$DB_ID" ] && die "RDS instance with prefix ${PREFIX}-db- not found"
    local current when
    current=$(aws_cmd rds describe-db-instances --db-instance-identifier "$DB_ID" --query 'DBInstances[0].DBInstanceClass' --output text)
    [ "$current" = "$target" ] && die "RDS is already $target"
    if [ "$RDS_NOW" = "true" ]; then when="IMMEDIATELY (downtime ~5-10 min; Multi-AZ shortens it)"; else when="in the next RDS maintenance window"; fi
    warn "RDS $DB_ID: $current -> $target, applied $when."
    warn "Larger classes increase monthly cost / consume credits faster."
    confirm "Proceed with RDS resize?"

    if [ "$RDS_NOW" = "true" ]; then
        aws_cmd rds modify-db-instance --db-instance-identifier "$DB_ID" --db-instance-class "$target" --apply-immediately >/dev/null
        log "Waiting for RDS to become available..."
        aws_cmd rds wait db-instance-available --db-instance-identifier "$DB_ID"
    else
        aws_cmd rds modify-db-instance --db-instance-identifier "$DB_ID" --db-instance-class "$target" --no-apply-immediately >/dev/null
        log "Change scheduled for the maintenance window."
    fi
    log "Update db_instance_class in terraform/terraform.tfvars to match $target."
}

#############################################
# grow-ebs
#############################################
cmd_grow_ebs() {
    local newsize="${1:-}"
    [[ "$newsize" =~ ^[0-9]+$ ]] || die "Usage: grow-ebs <GB> (integer)"
    discover
    [ -z "$VOLUME_ID" ] && die "EBS volume with tag Name=${PREFIX}-data not found"
    local cur
    cur=$(aws_cmd ec2 describe-volumes --volume-ids "$VOLUME_ID" --query 'Volumes[0].Size' --output text)
    [ "$newsize" -le "$cur" ] && die "EBS volumes can only grow (current: ${cur} GB)"

    warn "EBS $VOLUME_ID: ${cur} GB -> ${newsize} GB (no downtime). Cost grows with size; EBS cannot be shrunk later."
    confirm "Proceed with EBS grow?"

    aws_cmd ec2 modify-volume --volume-id "$VOLUME_ID" --size "$newsize" >/dev/null
    log "Waiting for volume modification (optimizing/completed)..."
    local state
    for _ in $(seq 1 60); do
        state=$(aws_cmd ec2 describe-volumes-modifications --volume-ids "$VOLUME_ID" \
            --query 'VolumesModifications[0].ModificationState' --output text)
        [ "$state" = "optimizing" ] || [ "$state" = "completed" ] && break
        [ "$state" = "failed" ] && die "Volume modification failed"
        sleep 10
    done

    log "Growing filesystem on the instance via SSM..."
    # Detect device backing /moodledata, grow partition if any, then xfs_growfs / resize2fs
    run_ssm 'set -e; DEV=$(findmnt -n -o SOURCE /moodledata); FS=$(findmnt -n -o FSTYPE /moodledata); if [[ "$DEV" =~ p?[0-9]+$ ]] && [ -e "$DEV" ] && lsblk -no TYPE "$DEV" | grep -q part; then DISK=$(lsblk -no PKNAME "$DEV"); PART=$(cat /sys/class/block/$(basename "$DEV")/partition); growpart "/dev/$DISK" "$PART" || true; fi; if [ "$FS" = xfs ]; then xfs_growfs /moodledata; else resize2fs "$DEV"; fi; df -h /moodledata'
    log "Done. Update the data volume size in Terraform variables to avoid drift."
}

#############################################
# enable-cloudfront-hint
#############################################
cmd_cloudfront_hint() {
    cat <<'EOF'
CloudFront (CDN for static assets) is managed by Terraform. To enable:
  1. In terraform/terraform.tfvars set:  enable_cloudfront = true
     (and cloudfront_price_class = "PriceClass_100" to keep cost low)
  2. cd terraform && terraform plan && terraform apply
  3. Point static asset delivery to the distribution domain (see docs/11-scaling.md).
Benefit: offloads image/CSS/JS traffic from EC2 and reduces CPU and bandwidth.
EOF
}

#############################################
# Argument parsing
#############################################
POSITIONAL=()
while [ $# -gt 0 ]; do
    case "$1" in
        --profile) PROFILE="${2:?missing value}"; shift 2 ;;
        --region)  REGION="${2:?missing value}"; shift 2 ;;
        --project) PROJECT="${2:?missing value}"; shift 2 ;;
        --env)     ENVIRONMENT_NAME="${2:?missing value}"; shift 2 ;;
        --yes|-y)  ASSUME_YES="true"; shift ;;
        --now)     RDS_NOW="true"; shift ;;
        -h|--help) usage; exit 0 ;;
        *) POSITIONAL+=("$1"); shift ;;
    esac
done

[ "${#POSITIONAL[@]}" -eq 0 ] && { usage; exit 1; }
COMMAND="${POSITIONAL[0]}"
ARG1="${POSITIONAL[1]:-}"

case "$COMMAND" in
    report)                  cmd_report ;;
    resize-ec2)              cmd_resize_ec2 "$ARG1" ;;
    resize-rds)              cmd_resize_rds "$ARG1" ;;
    grow-ebs)                cmd_grow_ebs "$ARG1" ;;
    enable-cloudfront-hint)  cmd_cloudfront_hint ;;
    *) usage; die "Unknown command: $COMMAND" ;;
esac
