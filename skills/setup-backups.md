# Setup Moodle Backups

Configures automated backup system for Moodle database, moodledata files, and configuration following the 3-2-1 backup strategy.

## When to use

Use this skill when the user wants to:
- Set up automated Moodle backups
- Configure database and file backups
- Implement 3-2-1 backup strategy
- Schedule backup jobs with cron
- Set up backup retention policies
- Configure S3 backup storage

## Instructions

You are an expert in Moodle backup strategies and disaster recovery. Your task is to configure a comprehensive backup system that protects against data loss.

### Context

This skill implements a production-ready backup system with:
- Daily automated database backups
- Weekly full moodledata backups
- Configuration file backups
- Local and S3 storage (3-2-1 strategy)
- Automatic retention management
- Backup verification and logging

### 3-2-1 Backup Strategy

**Rule:** 3 copies, 2 different media types, 1 offsite location

**Implementation:**
1. **Primary copy**: Live data on EBS volume
2. **Local backup**: Compressed backups on EBS
3. **Offsite backup**: S3 for disaster recovery

### Required prerequisites

- Moodle installed and running
- S3 bucket created for backups
- IAM role with S3 write permissions
- Sufficient disk space (20-30GB for local backups)
- Configuration file at `/root/moodle-config.env`

### Available automation

Script location: `deploy-moodle/scripts/06-setup-backups.sh`

The script fully automates backup configuration.

### Backup components

**1. Database backups:**
- Frequency: Daily at 2:00 AM
- Method: mysqldump with compression
- Retention: 7 daily, 4 weekly, 12 monthly
- Storage: Local + S3

**2. Moodledata backups:**
- Frequency: Weekly (Sunday 3:00 AM)
- Method: tar with gzip compression
- Retention: 4 weekly, 6 monthly
- Storage: Local + S3

**3. Configuration backups:**
- Frequency: Daily with database backup
- Files: config.php, Apache configs, PHP-FPM settings
- Retention: 30 days
- Storage: Local + S3

### Installation methods

**Method 1: Automated (Recommended)**
```bash
sudo deploy-moodle/scripts/06-setup-backups.sh
```

**Method 2: Manual** (follow steps below)

### Manual setup steps

1. **Create backup directories:**
   ```bash
   sudo mkdir -p /backups/{database,moodledata,config}
   sudo chown -R root:root /backups
   sudo chmod 750 /backups
   ```

2. **Create database backup script:**
   ```bash
   sudo vim /usr/local/bin/backup-moodle-db.sh
   ```

   Content:
   ```bash
   #!/bin/bash

   # Load configuration
   source /root/moodle-config.env

   # Backup settings
   BACKUP_DIR="/backups/database"
   DATE=$(date +%Y%m%d-%H%M%S)
   BACKUP_FILE="moodle-db-${DATE}.sql.gz"
   S3_BUCKET="${S3_BACKUP_BUCKET}"

   # Create backup
   echo "[$(date)] Starting database backup..."

   mysqldump -h $DB_HOST \
             -u $DB_USER \
             -p"$DB_PASSWORD" \
             --single-transaction \
             --quick \
             --lock-tables=false \
             $DB_NAME | gzip > "${BACKUP_DIR}/${BACKUP_FILE}"

   if [ $? -eq 0 ]; then
       echo "[$(date)] Database backup successful: ${BACKUP_FILE}"

       # Upload to S3
       aws s3 cp "${BACKUP_DIR}/${BACKUP_FILE}" \
                 "s3://${S3_BUCKET}/database/${BACKUP_FILE}"

       if [ $? -eq 0 ]; then
           echo "[$(date)] S3 upload successful"
       else
           echo "[$(date)] ERROR: S3 upload failed"
       fi
   else
       echo "[$(date)] ERROR: Database backup failed"
       exit 1
   fi

   # Retention: Keep last 7 daily backups locally
   find ${BACKUP_DIR} -name "moodle-db-*.sql.gz" -mtime +7 -delete

   # Retention: Keep last 30 days in S3
   aws s3 ls "s3://${S3_BUCKET}/database/" | \
       awk '{print $4}' | \
       sort -r | \
       tail -n +31 | \
       xargs -I {} aws s3 rm "s3://${S3_BUCKET}/database/{}"

   echo "[$(date)] Backup completed"
   ```

3. **Create moodledata backup script:**
   ```bash
   sudo vim /usr/local/bin/backup-moodledata.sh
   ```

   Content:
   ```bash
   #!/bin/bash

   # Load configuration
   source /root/moodle-config.env

   # Backup settings
   BACKUP_DIR="/backups/moodledata"
   DATE=$(date +%Y%m%d-%H%M%S)
   BACKUP_FILE="moodledata-${DATE}.tar.gz"
   S3_BUCKET="${S3_BACKUP_BUCKET}"
   MOODLE_DATA="/moodledata"

   echo "[$(date)] Starting moodledata backup..."

   # Create backup (exclude cache and temp)
   tar -czf "${BACKUP_DIR}/${BACKUP_FILE}" \
       --exclude="${MOODLE_DATA}/cache" \
       --exclude="${MOODLE_DATA}/localcache" \
       --exclude="${MOODLE_DATA}/temp" \
       --exclude="${MOODLE_DATA}/sessions" \
       -C / moodledata

   if [ $? -eq 0 ]; then
       echo "[$(date)] Moodledata backup successful: ${BACKUP_FILE}"

       # Upload to S3
       aws s3 cp "${BACKUP_DIR}/${BACKUP_FILE}" \
                 "s3://${S3_BUCKET}/moodledata/${BACKUP_FILE}"

       if [ $? -eq 0 ]; then
           echo "[$(date)] S3 upload successful"
       else
           echo "[$(date)] ERROR: S3 upload failed"
       fi
   else
       echo "[$(date)] ERROR: Moodledata backup failed"
       exit 1
   fi

   # Retention: Keep last 4 weekly backups locally
   find ${BACKUP_DIR} -name "moodledata-*.tar.gz" -mtime +28 -delete

   # Retention: Keep last 12 weeks in S3
   aws s3 ls "s3://${S3_BUCKET}/moodledata/" | \
       awk '{print $4}' | \
       sort -r | \
       tail -n +13 | \
       xargs -I {} aws s3 rm "s3://${S3_BUCKET}/moodledata/{}"

   echo "[$(date)] Backup completed"
   ```

4. **Create config backup script:**
   ```bash
   sudo vim /usr/local/bin/backup-config.sh
   ```

   Content:
   ```bash
   #!/bin/bash

   # Backup settings
   BACKUP_DIR="/backups/config"
   DATE=$(date +%Y%m%d-%H%M%S)
   BACKUP_FILE="config-${DATE}.tar.gz"
   S3_BUCKET="${S3_BACKUP_BUCKET}"

   echo "[$(date)] Starting config backup..."

   # Create backup of configuration files
   tar -czf "${BACKUP_DIR}/${BACKUP_FILE}" \
       /var/www/html/moodle/config.php \
       /etc/httpd/conf.d/moodle.conf \
       /etc/php-fpm.d/www.conf \
       /etc/php.ini \
       /root/moodle-config.env \
       2>/dev/null

   if [ $? -eq 0 ]; then
       echo "[$(date)] Config backup successful: ${BACKUP_FILE}"

       # Upload to S3
       aws s3 cp "${BACKUP_DIR}/${BACKUP_FILE}" \
                 "s3://${S3_BUCKET}/config/${BACKUP_FILE}"
   fi

   # Retention: Keep last 30 days
   find ${BACKUP_DIR} -name "config-*.tar.gz" -mtime +30 -delete

   echo "[$(date)] Backup completed"
   ```

5. **Set permissions:**
   ```bash
   sudo chmod 750 /usr/local/bin/backup-*.sh
   sudo chown root:root /usr/local/bin/backup-*.sh
   ```

6. **Configure cron jobs:**
   ```bash
   sudo vim /etc/cron.d/moodle-backups
   ```

   Content:
   ```cron
   # Daily database backup at 2:00 AM
   0 2 * * * root /usr/local/bin/backup-moodle-db.sh >> /var/log/moodle-backups.log 2>&1

   # Daily config backup at 2:30 AM
   30 2 * * * root /usr/local/bin/backup-config.sh >> /var/log/moodle-backups.log 2>&1

   # Weekly moodledata backup on Sunday at 3:00 AM
   0 3 * * 0 root /usr/local/bin/backup-moodledata.sh >> /var/log/moodle-backups.log 2>&1
   ```

   Set permissions:
   ```bash
   sudo chmod 644 /etc/cron.d/moodle-backups
   ```

7. **Test backups:**
   ```bash
   # Test database backup
   sudo /usr/local/bin/backup-moodle-db.sh

   # Test config backup
   sudo /usr/local/bin/backup-config.sh

   # Verify files created
   ls -lh /backups/database/
   ls -lh /backups/config/

   # Verify S3 upload
   aws s3 ls s3://your-bucket/database/
   aws s3 ls s3://your-bucket/config/
   ```

### Backup sizes and timing

**Database:**
- Initial: ~100-200 MB
- After 1 year: ~500 MB - 2 GB
- Backup time: 1-5 minutes
- Compressed: 10-20% of original size

**Moodledata:**
- Depends on uploaded files
- Typical: 5-50 GB
- Backup time: 10-60 minutes
- Compressed: 30-50% of original size

**Config:**
- Size: < 1 MB
- Backup time: < 5 seconds

### Storage requirements

**Local storage (EBS):**
- Database: 7 days × 200 MB = ~1.4 GB
- Moodledata: 4 weeks × 15 GB = ~60 GB
- Config: 30 days × 1 MB = ~30 MB
- **Total:** ~65-70 GB

**S3 storage:**
- Database: 30 days × 200 MB = ~6 GB
- Moodledata: 12 weeks × 15 GB = ~180 GB
- Config: 30 days × 1 MB = ~30 MB
- **Total:** ~190 GB
- **Monthly cost:** ~$4-5 USD (Standard tier)

### Monitoring backups

**Check backup status:**
```bash
# View backup log
sudo tail -100 /var/log/moodle-backups.log

# Check last backup times
stat /backups/database/moodle-db-*.sql.gz | tail -1
stat /backups/moodledata/moodledata-*.tar.gz | tail -1

# Check backup sizes
du -sh /backups/*

# Check S3 contents
aws s3 ls s3://your-bucket/ --recursive --human-readable
```

**Create backup monitoring script:**
```bash
#!/bin/bash
echo "=== Moodle Backup Status ==="

# Last database backup
DB_LAST=$(ls -t /backups/database/moodle-db-*.sql.gz 2>/dev/null | head -1)
if [ -n "$DB_LAST" ]; then
    DB_AGE=$(( ($(date +%s) - $(stat -c %Y "$DB_LAST")) / 3600 ))
    echo "Database: ${DB_AGE}h ago ($(du -h "$DB_LAST" | cut -f1))"
else
    echo "Database: NO BACKUPS FOUND"
fi

# Last moodledata backup
DATA_LAST=$(ls -t /backups/moodledata/moodledata-*.tar.gz 2>/dev/null | head -1)
if [ -n "$DATA_LAST" ]; then
    DATA_AGE=$(( ($(date +%s) - $(stat -c %Y "$DATA_LAST")) / 86400 ))
    echo "Moodledata: ${DATA_AGE}d ago ($(du -h "$DATA_LAST" | cut -f1))"
else
    echo "Moodledata: NO BACKUPS FOUND"
fi

# Disk usage
echo ""
echo "Disk usage:"
df -h /backups | grep -v Filesystem
```

### Restore procedures

**Restore database:**
```bash
# List available backups
ls -lh /backups/database/

# Or from S3
aws s3 ls s3://your-bucket/database/

# Restore from local
gunzip < /backups/database/moodle-db-YYYYMMDD-HHMMSS.sql.gz | \
    mysql -h $DB_HOST -u $DB_USER -p"$DB_PASSWORD" $DB_NAME

# Or restore from S3
aws s3 cp s3://your-bucket/database/moodle-db-YYYYMMDD-HHMMSS.sql.gz - | \
    gunzip | \
    mysql -h $DB_HOST -u $DB_USER -p"$DB_PASSWORD" $DB_NAME
```

**Restore moodledata:**
```bash
# Stop services first
sudo systemctl stop httpd php-fpm

# Backup current data
sudo mv /moodledata /moodledata.old

# Restore from local
sudo tar -xzf /backups/moodledata/moodledata-YYYYMMDD-HHMMSS.tar.gz -C /

# Or restore from S3
aws s3 cp s3://your-bucket/moodledata/moodledata-YYYYMMDD-HHMMSS.tar.gz - | \
    sudo tar -xzf - -C /

# Fix permissions
sudo chown -R apache:apache /moodledata
sudo chmod -R 770 /moodledata

# Restart services
sudo systemctl start php-fpm httpd
```

**Restore config:**
```bash
# Download from S3
aws s3 cp s3://your-bucket/config/config-YYYYMMDD-HHMMSS.tar.gz /tmp/

# Extract
sudo tar -xzf /tmp/config-YYYYMMDD-HHMMSS.tar.gz -C /

# Restart services
sudo systemctl restart httpd php-fpm
```

### Common issues

**Backup fails with "disk full":**
```bash
# Check disk space
df -h /backups

# Clean old backups manually
find /backups -name "*.gz" -mtime +7 -delete

# Consider increasing EBS volume size
```

**S3 upload fails:**
```bash
# Check IAM permissions
aws s3 ls s3://your-bucket/

# Check network connectivity
curl -I https://s3.amazonaws.com

# Verify IAM role attached to EC2
aws sts get-caller-identity
```

**Database backup too large:**
```bash
# Check database size
mysql -h $DB_HOST -u $DB_USER -p"$DB_PASSWORD" -e \
    "SELECT table_schema AS 'Database',
            ROUND(SUM(data_length + index_length) / 1024 / 1024, 2) AS 'Size (MB)'
     FROM information_schema.tables
     WHERE table_schema = 'moodle'
     GROUP BY table_schema;"

# Purge old data in Moodle
# Site admin → Server → Cleanup
```

**Moodledata backup takes too long:**
```bash
# Check what's using space
du -sh /moodledata/* | sort -h

# Consider excluding more directories
# Edit backup script to exclude:
# - /moodledata/trashdir
# - /moodledata/repository (if using external storage)
```

### Security considerations

1. **Backup encryption:** Enable S3 bucket encryption (AES-256 or KMS)
2. **Access control:** Restrict IAM permissions to specific S3 bucket
3. **File permissions:** Backups contain sensitive data (640/750 permissions)
4. **Secure credentials:** Never store DB password in backup scripts
5. **S3 versioning:** Enable versioning for additional protection

### S3 lifecycle policy

Configure S3 lifecycle rules for cost optimization:

```json
{
    "Rules": [
        {
            "Id": "MoveToGlacier",
            "Status": "Enabled",
            "Prefix": "database/",
            "Transitions": [
                {
                    "Days": 30,
                    "StorageClass": "GLACIER"
                }
            ]
        },
        {
            "Id": "DeleteOld",
            "Status": "Enabled",
            "Prefix": "",
            "Expiration": {
                "Days": 365
            }
        }
    ]
}
```

### Expected output

```
✓ Backup directories created
✓ Database backup script configured
✓ Moodledata backup script configured
✓ Config backup script configured
✓ Cron jobs scheduled
✓ Backup monitoring script created
✓ S3 bucket configured

Backup schedule:
  - Database: Daily at 2:00 AM (7 days local, 30 days S3)
  - Config: Daily at 2:30 AM (30 days)
  - Moodledata: Sunday at 3:00 AM (4 weeks local, 12 weeks S3)

Storage requirements:
  - Local: ~70 GB
  - S3: ~190 GB (~$5/month)

Test backups:
  sudo /usr/local/bin/backup-moodle-db.sh
  sudo tail /var/log/moodle-backups.log

Monitor:
  sudo backup-status.sh
```

## Example usage

**User:** "Set up automated backups for my Moodle site. I want daily database backups and weekly file backups stored in S3."

**Assistant:** I'll configure automated backups with S3 storage following the 3-2-1 backup strategy.

[Loads configuration from /root/moodle-config.env]
[Creates backup directories]
[Creates database backup script with S3 upload]
[Creates moodledata backup script]
[Creates config backup script]
[Configures cron jobs]
[Tests database backup]

Backup system configured successfully!

**Schedule:**
- Database: Daily at 2:00 AM → kept 7 days local, 30 days S3
- Config: Daily at 2:30 AM → kept 30 days
- Moodledata: Sundays at 3:00 AM → kept 4 weeks local, 12 weeks S3

**Storage:**
- Local: ~70 GB (managed automatically)
- S3: ~190 GB (~$5/month)

**First backup created:**
- Database: moodle-db-20260202-140532.sql.gz (156 MB)
- Uploaded to: s3://acg-moodle-backups/database/

**Monitor backups:**
```bash
sudo tail -f /var/log/moodle-backups.log
```

Your data is now protected with the 3-2-1 strategy: 3 copies, 2 media types, 1 offsite.

---

**User:** "The moodledata backup is taking 2 hours and filling up my disk. Can you optimize it?"

**Assistant:** Let me optimize the moodledata backup process.

[Checks moodledata size breakdown]

I found the issue:
- Total moodledata: 180 GB
- Cache directories: 45 GB
- Temp files: 12 GB
- Actual course data: 123 GB

**Optimizing:**
1. Excluding cache and temp from backups (already done)
2. Adding exclusion for old trashdir files (30+ days)
3. Enabling incremental backups for large installations

[Updates backup script with additional exclusions]
[Adds rsync-based incremental backup option]
[Tests optimized backup]

**Results:**
- Backup size: 180 GB → 95 GB (compressed to 32 GB)
- Backup time: 2 hours → 35 minutes
- Disk usage: Reduced by 60%

The backup now excludes:
- Cache and localcache directories
- Temporary files and sessions
- Files in trash older than 30 days
- PHP session data

Your next weekly backup will complete much faster!
