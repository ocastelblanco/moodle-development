# SSM Automation aws:executeScript handler (Python 3.11).
# Grows the /moodledata EBS volume by a percentage, capped at a maximum size.
# Idempotent: skips when a modification is in progress, during the AWS
# 6-hour cooldown between modifications, or when the cap is reached.
import datetime
import math
import time

import boto3
from botocore.exceptions import ClientError

COOLDOWN_SECONDS = 6 * 3600
WAIT_TIMEOUT_SECONDS = 480


def _publish(topic_arn, subject, message):
    if topic_arn:
        boto3.client("sns").publish(TopicArn=topic_arn, Subject=subject[:100], Message=message)


def handler(events, context):
    volume_id = events["VolumeId"]
    increment_pct = float(events["IncrementPercent"])
    max_size_gb = int(events["MaxSizeGb"])
    topic_arn = events.get("TopicArn", "")
    ec2 = boto3.client("ec2")

    # Skip if a previous modification is still running or within cooldown.
    try:
        mods = ec2.describe_volumes_modifications(VolumeIds=[volume_id]).get("VolumesModifications", [])
    except ClientError as err:
        # Volumes never modified return InvalidVolumeModification.NotFound.
        if "NotFound" not in str(err):
            raise
        mods = []
    now = datetime.datetime.now(datetime.timezone.utc)
    for mod in mods:
        state = mod.get("ModificationState")
        if state == "modifying":
            msg = f"EBS autogrow skipped: volume {volume_id} already has a modification in progress."
            _publish(topic_arn, "EBS autogrow skipped", msg)
            return {"Action": "skipped", "Message": msg, "NewSizeGb": 0}
        start = mod.get("StartTime")
        if state != "failed" and start and (now - start).total_seconds() < COOLDOWN_SECONDS:
            msg = (f"EBS autogrow skipped: volume {volume_id} was modified at {start.isoformat()}; "
                   "AWS requires 6 hours between modifications.")
            _publish(topic_arn, "EBS autogrow skipped", msg)
            return {"Action": "skipped", "Message": msg, "NewSizeGb": 0}

    current_gb = ec2.describe_volumes(VolumeIds=[volume_id])["Volumes"][0]["Size"]
    if current_gb >= max_size_gb:
        msg = (f"EBS autogrow skipped: volume {volume_id} is {current_gb} GB, already at or above the "
               f"configured maximum of {max_size_gb} GB. Manual action required.")
        _publish(topic_arn, "EBS autogrow: maximum size reached", msg)
        return {"Action": "skipped", "Message": msg, "NewSizeGb": current_gb}

    new_gb = min(max_size_gb, max(current_gb + 1, math.ceil(current_gb * (1 + increment_pct / 100))))
    ec2.modify_volume(VolumeId=volume_id, Size=new_gb)

    # Wait until the new size is usable by the OS (optimizing or completed).
    deadline = time.time() + WAIT_TIMEOUT_SECONDS
    state = "modifying"
    while time.time() < deadline:
        mod = ec2.describe_volumes_modifications(VolumeIds=[volume_id])["VolumesModifications"][0]
        state = mod["ModificationState"]
        if state in ("optimizing", "completed"):
            break
        if state == "failed":
            raise RuntimeError(f"ModifyVolume failed for {volume_id}: {mod.get('StatusMessage', '')}")
        time.sleep(10)
    else:
        raise RuntimeError(f"Timed out waiting for {volume_id} modification (last state: {state}).")

    msg = (f"EBS volume {volume_id} grown from {current_gb} GB to {new_gb} GB (state: {state}). "
           f"IMPORTANT: set data_volume_size = {new_gb} in terraform.tfvars before the next "
           f"terraform apply (EBS volumes cannot shrink).")
    return {"Action": "grown", "Message": msg, "NewSizeGb": new_gb}
