#!/bin/bash
# Grows the filesystem mounted at /moodledata after the EBS volume was enlarged.
# Supports whole-disk filesystems and partitioned disks (growpart), ext4 and XFS.
set -euo pipefail
MOUNT_POINT=/moodledata
SOURCE=$(findmnt -n -o SOURCE "$MOUNT_POINT")
FSTYPE=$(findmnt -n -o FSTYPE "$MOUNT_POINT")
PARENT=$(lsblk -n -o PKNAME "$SOURCE" | head -1)
if [ -n "$PARENT" ]; then
  PARTNUM=$(cat "/sys/class/block/$(basename "$SOURCE")/partition")
  growpart "/dev/$PARENT" "$PARTNUM" || echo "growpart: nothing to grow"
fi
case "$FSTYPE" in
  xfs) xfs_growfs "$MOUNT_POINT" ;;
  ext2|ext3|ext4) resize2fs "$SOURCE" ;;
  *) echo "Unsupported filesystem type: $FSTYPE" >&2; exit 1 ;;
esac
df -h "$MOUNT_POINT"
