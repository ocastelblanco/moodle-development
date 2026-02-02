# Setup Moodle Monitoring

Configures comprehensive monitoring system using AWS CloudWatch for metrics, logs, and alarms to ensure Moodle availability and performance.

## When to use

Use this skill when the user wants to:
- Set up CloudWatch monitoring for Moodle
- Configure performance metrics and alarms
- Monitor system health (CPU, memory, disk)
- Track Moodle-specific metrics
- Set up log aggregation
- Create dashboards for visibility
- Receive alerts for issues

## Instructions

You are an expert in AWS CloudWatch monitoring and Moodle operations. Your task is to configure comprehensive monitoring that provides visibility and proactive alerting.

### Context

This skill implements production-grade monitoring with:
- CloudWatch Agent for custom metrics
- Log aggregation (Apache, PHP-FPM, Moodle, system)
- Proactive alarms with SNS notifications
- Custom dashboards for visualization
- Memory monitoring (critical for t4g instances)
- Moodle-specific health checks

### Required prerequisites

- EC2 instance with IAM role for CloudWatch
- SNS topic for alarm notifications
- CloudWatch Logs access configured
- Sufficient IAM permissions
- Email configured for alarm notifications

### Available automation

Script location: `deploy-moodle/scripts/07-setup-monitoring.sh`

The script fully automates monitoring configuration.

### Monitoring components

**1. System metrics:**
- CPU utilization (per core and aggregate)
- Memory usage (used, available, percentage)
- Disk usage and I/O
- Network traffic
- Swap usage

**2. Application metrics:**
- Apache connections and requests/second
- PHP-FPM process count and status
- Database connections
- Moodle cron execution status

**3. Log monitoring:**
- Apache access and error logs
- PHP-FPM errors
- Moodle application logs
- System authentication logs
- CloudWatch Agent logs

**4. Alarms:**
- High CPU (>80% for 5 minutes)
- High memory (>85% for 5 minutes)
- Low disk space (<15%)
- Service failures (Apache, PHP-FPM down)
- Database connection failures
- SSL certificate expiration (30 days)

### Installation methods

**Method 1: Automated (Recommended)**
```bash
sudo deploy-moodle/scripts/07-setup-monitoring.sh
```

**Method 2: Manual** (follow steps below)

### Manual setup steps

1. **Install CloudWatch Agent:**
   ```bash
   # Download agent
   wget https://s3.amazonaws.com/amazoncloudwatch-agent/amazon_linux/arm64/latest/amazon-cloudwatch-agent.rpm

   # Install
   sudo rpm -U amazon-cloudwatch-agent.rpm

   # Verify installation
   /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
       -a query -m ec2 -c default -s
   ```

2. **Create CloudWatch Agent configuration:**
   ```bash
   sudo vim /opt/aws/amazon-cloudwatch-agent/etc/config.json
   ```

   Content:
   ```json
   {
     "agent": {
       "metrics_collection_interval": 60,
       "run_as_user": "root"
     },
     "metrics": {
       "namespace": "Moodle/Production",
       "metrics_collected": {
         "cpu": {
           "measurement": [
             {
               "name": "cpu_usage_idle",
               "rename": "CPU_IDLE",
               "unit": "Percent"
             },
             {
               "name": "cpu_usage_iowait",
               "rename": "CPU_IOWAIT",
               "unit": "Percent"
             }
           ],
           "metrics_collection_interval": 60,
           "totalcpu": false
         },
         "disk": {
           "measurement": [
             {
               "name": "used_percent",
               "rename": "DISK_USED",
               "unit": "Percent"
             },
             {
               "name": "inodes_free",
               "rename": "DISK_INODES_FREE",
               "unit": "Count"
             }
           ],
           "metrics_collection_interval": 60,
           "resources": [
             "/"
           ]
         },
         "diskio": {
           "measurement": [
             {
               "name": "io_time",
               "rename": "DISK_IO_TIME",
               "unit": "Milliseconds"
             },
             {
               "name": "reads",
               "rename": "DISK_READS",
               "unit": "Count"
             },
             {
               "name": "writes",
               "rename": "DISK_WRITES",
               "unit": "Count"
             }
           ],
           "metrics_collection_interval": 60
         },
         "mem": {
           "measurement": [
             {
               "name": "mem_used_percent",
               "rename": "MEM_USED",
               "unit": "Percent"
             },
             {
               "name": "mem_available",
               "rename": "MEM_AVAILABLE",
               "unit": "Megabytes"
             },
             {
               "name": "mem_total",
               "rename": "MEM_TOTAL",
               "unit": "Megabytes"
             }
           ],
           "metrics_collection_interval": 60
         },
         "netstat": {
           "measurement": [
             {
               "name": "tcp_established",
               "rename": "TCP_CONNECTIONS",
               "unit": "Count"
             },
             {
               "name": "tcp_time_wait",
               "rename": "TCP_TIME_WAIT",
               "unit": "Count"
             }
           ],
           "metrics_collection_interval": 60
         },
         "swap": {
           "measurement": [
             {
               "name": "swap_used_percent",
               "rename": "SWAP_USED",
               "unit": "Percent"
             }
           ],
           "metrics_collection_interval": 60
         }
       }
     },
     "logs": {
       "logs_collected": {
         "files": {
           "collect_list": [
             {
               "file_path": "/var/log/httpd/moodle-access.log",
               "log_group_name": "/moodle/apache/access",
               "log_stream_name": "{instance_id}",
               "retention_in_days": 30
             },
             {
               "file_path": "/var/log/httpd/moodle-error.log",
               "log_group_name": "/moodle/apache/error",
               "log_stream_name": "{instance_id}",
               "retention_in_days": 30
             },
             {
               "file_path": "/var/log/php-fpm/error.log",
               "log_group_name": "/moodle/php-fpm/error",
               "log_stream_name": "{instance_id}",
               "retention_in_days": 30
             },
             {
               "file_path": "/var/log/messages",
               "log_group_name": "/moodle/system/messages",
               "log_stream_name": "{instance_id}",
               "retention_in_days": 7
             },
             {
               "file_path": "/var/log/memory-monitor.log",
               "log_group_name": "/moodle/system/memory",
               "log_stream_name": "{instance_id}",
               "retention_in_days": 30
             }
           ]
         }
       }
     }
   }
   ```

3. **Start CloudWatch Agent:**
   ```bash
   sudo /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
       -a fetch-config \
       -m ec2 \
       -s \
       -c file:/opt/aws/amazon-cloudwatch-agent/etc/config.json

   # Enable auto-start
   sudo systemctl enable amazon-cloudwatch-agent
   sudo systemctl status amazon-cloudwatch-agent
   ```

4. **Create SNS topic for alarms:**
   ```bash
   # Create topic
   aws sns create-topic --name moodle-alerts

   # Subscribe email
   aws sns subscribe \
       --topic-arn arn:aws:sns:us-east-1:ACCOUNT:moodle-alerts \
       --protocol email \
       --notification-endpoint admin@yourdomain.com

   # Confirm subscription via email
   ```

5. **Create CloudWatch alarms:**

   **High CPU alarm:**
   ```bash
   aws cloudwatch put-metric-alarm \
       --alarm-name moodle-high-cpu \
       --alarm-description "CPU usage above 80%" \
       --metric-name CPUUtilization \
       --namespace AWS/EC2 \
       --statistic Average \
       --period 300 \
       --threshold 80 \
       --comparison-operator GreaterThanThreshold \
       --datapoints-to-alarm 1 \
       --evaluation-periods 1 \
       --dimensions Name=InstanceId,Value=i-xxxxx \
       --alarm-actions arn:aws:sns:us-east-1:ACCOUNT:moodle-alerts
   ```

   **High memory alarm:**
   ```bash
   aws cloudwatch put-metric-alarm \
       --alarm-name moodle-high-memory \
       --alarm-description "Memory usage above 85%" \
       --metric-name MEM_USED \
       --namespace Moodle/Production \
       --statistic Average \
       --period 300 \
       --threshold 85 \
       --comparison-operator GreaterThanThreshold \
       --datapoints-to-alarm 1 \
       --evaluation-periods 1 \
       --dimensions Name=InstanceId,Value=i-xxxxx \
       --alarm-actions arn:aws:sns:us-east-1:ACCOUNT:moodle-alerts
   ```

   **Low disk space alarm:**
   ```bash
   aws cloudwatch put-metric-alarm \
       --alarm-name moodle-low-disk \
       --alarm-description "Disk usage above 85%" \
       --metric-name DISK_USED \
       --namespace Moodle/Production \
       --statistic Average \
       --period 300 \
       --threshold 85 \
       --comparison-operator GreaterThanThreshold \
       --datapoints-to-alarm 1 \
       --evaluation-periods 1 \
       --dimensions Name=InstanceId,Value=i-xxxxx,Name=path,Value=/ \
       --alarm-actions arn:aws:sns:us-east-1:ACCOUNT:moodle-alerts
   ```

   **Service health check alarm:**
   ```bash
   aws cloudwatch put-metric-alarm \
       --alarm-name moodle-service-down \
       --alarm-description "HTTP check failing" \
       --metric-name StatusCheckFailed \
       --namespace AWS/EC2 \
       --statistic Maximum \
       --period 60 \
       --threshold 1 \
       --comparison-operator GreaterThanOrEqualToThreshold \
       --datapoints-to-alarm 2 \
       --evaluation-periods 2 \
       --dimensions Name=InstanceId,Value=i-xxxxx \
       --alarm-actions arn:aws:sns:us-east-1:ACCOUNT:moodle-alerts
   ```

6. **Create custom health check script:**
   ```bash
   sudo vim /usr/local/bin/moodle-health-check.sh
   ```

   Content:
   ```bash
   #!/bin/bash

   # CloudWatch namespace
   NAMESPACE="Moodle/Production"
   INSTANCE_ID=$(ec2-metadata --instance-id | cut -d " " -f 2)

   # Check Apache
   if systemctl is-active --quiet httpd; then
       APACHE_STATUS=1
   else
       APACHE_STATUS=0
   fi

   aws cloudwatch put-metric-data \
       --namespace ${NAMESPACE} \
       --metric-name ApacheStatus \
       --value ${APACHE_STATUS} \
       --dimensions InstanceId=${INSTANCE_ID}

   # Check PHP-FPM
   if systemctl is-active --quiet php-fpm; then
       PHP_STATUS=1
   else
       PHP_STATUS=0
   fi

   aws cloudwatch put-metric-data \
       --namespace ${NAMESPACE} \
       --metric-name PHPFPMStatus \
       --value ${PHP_STATUS} \
       --dimensions InstanceId=${INSTANCE_ID}

   # Check PHP-FPM process count
   PHP_PROCESSES=$(ps aux | grep php-fpm | grep -v grep | wc -l)

   aws cloudwatch put-metric-data \
       --namespace ${NAMESPACE} \
       --metric-name PHPFPMProcesses \
       --value ${PHP_PROCESSES} \
       --dimensions InstanceId=${INSTANCE_ID}

   # Check database connectivity
   source /root/moodle-config.env
   if mysql -h $DB_HOST -u $DB_USER -p"$DB_PASSWORD" -e "SELECT 1;" &>/dev/null; then
       DB_STATUS=1
   else
       DB_STATUS=0
   fi

   aws cloudwatch put-metric-data \
       --namespace ${NAMESPACE} \
       --metric-name DatabaseStatus \
       --value ${DB_STATUS} \
       --dimensions InstanceId=${INSTANCE_ID}

   # Check SSL certificate expiration
   CERT_FILE="/etc/letsencrypt/live/$(hostname -f)/fullchain.pem"
   if [ -f "$CERT_FILE" ]; then
       CERT_DAYS=$(( ($(date -d "$(openssl x509 -enddate -noout -in "$CERT_FILE" | cut -d= -f2)" +%s) - $(date +%s)) / 86400 ))

       aws cloudwatch put-metric-data \
           --namespace ${NAMESPACE} \
           --metric-name SSLCertDaysRemaining \
           --value ${CERT_DAYS} \
           --dimensions InstanceId=${INSTANCE_ID}
   fi

   # Check last Moodle cron execution
   if [ -f "/moodledata/cron.lock" ]; then
       CRON_AGE=$(( ($(date +%s) - $(stat -c %Y /moodledata/cron.lock)) / 60 ))

       aws cloudwatch put-metric-data \
           --namespace ${NAMESPACE} \
           --metric-name MoodleCronAge \
           --value ${CRON_AGE} \
           --dimensions InstanceId=${INSTANCE_ID} \
           --unit Minutes
   fi
   ```

   Make executable:
   ```bash
   sudo chmod +x /usr/local/bin/moodle-health-check.sh
   ```

7. **Schedule health checks:**
   ```bash
   echo '*/5 * * * * root /usr/local/bin/moodle-health-check.sh' | \
       sudo tee /etc/cron.d/moodle-monitoring
   sudo chmod 644 /etc/cron.d/moodle-monitoring
   ```

8. **Create monitoring dashboard:**
   ```bash
   aws cloudwatch put-dashboard \
       --dashboard-name Moodle-Production \
       --dashboard-body file://dashboard.json
   ```

   Dashboard JSON:
   ```json
   {
     "widgets": [
       {
         "type": "metric",
         "properties": {
           "metrics": [
             ["AWS/EC2", "CPUUtilization", {"stat": "Average"}]
           ],
           "period": 300,
           "stat": "Average",
           "region": "us-east-1",
           "title": "CPU Utilization"
         }
       },
       {
         "type": "metric",
         "properties": {
           "metrics": [
             ["Moodle/Production", "MEM_USED", {"stat": "Average"}]
           ],
           "period": 300,
           "stat": "Average",
           "region": "us-east-1",
           "title": "Memory Usage %"
         }
       },
       {
         "type": "metric",
         "properties": {
           "metrics": [
             ["Moodle/Production", "DISK_USED", {"stat": "Average"}]
           ],
           "period": 300,
           "stat": "Average",
           "region": "us-east-1",
           "title": "Disk Usage %"
         }
       },
       {
         "type": "metric",
         "properties": {
           "metrics": [
             ["Moodle/Production", "PHPFPMProcesses", {"stat": "Average"}]
           ],
           "period": 300,
           "stat": "Average",
           "region": "us-east-1",
           "title": "PHP-FPM Processes"
         }
       }
     ]
   }
   ```

### Verification steps

1. **Check CloudWatch Agent:**
   ```bash
   sudo systemctl status amazon-cloudwatch-agent

   # View logs
   sudo tail -f /opt/aws/amazon-cloudwatch-agent/logs/amazon-cloudwatch-agent.log
   ```

2. **Verify metrics in CloudWatch:**
   ```bash
   # List custom metrics
   aws cloudwatch list-metrics --namespace Moodle/Production

   # Get latest CPU metric
   aws cloudwatch get-metric-statistics \
       --namespace AWS/EC2 \
       --metric-name CPUUtilization \
       --dimensions Name=InstanceId,Value=i-xxxxx \
       --start-time $(date -u -d '10 minutes ago' +%Y-%m-%dT%H:%M:%S) \
       --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
       --period 300 \
       --statistics Average
   ```

3. **Check log groups:**
   ```bash
   # List log groups
   aws logs describe-log-groups --log-group-name-prefix /moodle/

   # View recent logs
   aws logs tail /moodle/apache/error --follow
   ```

4. **Test alarms:**
   ```bash
   # Describe alarms
   aws cloudwatch describe-alarms --alarm-name-prefix moodle-

   # Test alarm (create artificial high CPU)
   yes > /dev/null &
   # Wait 5 minutes, then kill process
   killall yes
   ```

### Monitoring best practices

**1. Baseline establishment:**
- Monitor for 1 week to establish normal patterns
- Adjust alarm thresholds based on actual usage
- Document peak usage times

**2. Alarm fatigue prevention:**
- Set appropriate thresholds (not too sensitive)
- Use evaluation periods to avoid false alarms
- Group related alarms

**3. Log retention:**
- Keep critical logs for 30 days
- Archive important logs to S3 for compliance
- Rotate logs to manage costs

**4. Cost optimization:**
- Use appropriate metric collection intervals
- Aggregate logs before sending to CloudWatch
- Set retention policies on log groups

### CloudWatch costs

**Typical monthly costs for single server:**
- Custom metrics: 10 metrics × $0.30 = $3.00
- Log ingestion: 5 GB × $0.50 = $2.50
- Log storage: 10 GB × $0.03 = $0.30
- Alarms: 10 alarms × $0.10 = $1.00
- Dashboard: 1 × $3.00 = $3.00
- **Total:** ~$10/month

### Advanced monitoring

**1. Moodle-specific metrics:**
```bash
# Active users
mysql -h $DB_HOST -u $DB_USER -p"$DB_PASSWORD" $DB_NAME -e \
    "SELECT COUNT(DISTINCT userid) FROM mdl_logstore_standard_log
     WHERE timecreated > UNIX_TIMESTAMP(NOW() - INTERVAL 5 MINUTE);"

# Send to CloudWatch
aws cloudwatch put-metric-data \
    --namespace Moodle/Production \
    --metric-name ActiveUsers \
    --value $ACTIVE_USERS
```

**2. Response time monitoring:**
```bash
# Average response time from access log
RESPONSE_TIME=$(awk '{sum+=$10; count++} END {print sum/count}' \
    /var/log/httpd/moodle-access.log)

aws cloudwatch put-metric-data \
    --namespace Moodle/Production \
    --metric-name ResponseTime \
    --value $RESPONSE_TIME \
    --unit Milliseconds
```

**3. Error rate monitoring:**
```bash
# Count 5xx errors in last 5 minutes
ERROR_COUNT=$(grep -c "HTTP/1.1\" 5[0-9][0-9]" \
    /var/log/httpd/moodle-access.log)

aws cloudwatch put-metric-data \
    --namespace Moodle/Production \
    --metric-name ErrorCount \
    --value $ERROR_COUNT
```

### Integration with Moodle

**Enable Moodle error logging:**
```php
// In config.php
$CFG->debug = E_ALL;
$CFG->debugdisplay = false;
$CFG->debugsyslog = true;
$CFG->errorlog = '/moodledata/moodle.log';
```

**Monitor Moodle events:**
```bash
# Parse Moodle log for critical events
sudo tail -f /moodledata/moodle.log | grep -E "ERROR|CRITICAL|FATAL"
```

### Troubleshooting monitoring

**Agent not sending metrics:**
```bash
# Check agent status
sudo /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
    -a query -m ec2 -c default -s

# Check IAM permissions
aws iam get-role --role-name MoodleInstanceRole

# Test metric manually
aws cloudwatch put-metric-data \
    --namespace Test \
    --metric-name TestMetric \
    --value 1.0
```

**Logs not appearing:**
```bash
# Check log file permissions
ls -la /var/log/httpd/moodle-*.log

# Verify agent has read access
sudo -u cwagent cat /var/log/httpd/moodle-error.log

# Check agent logs
sudo tail /opt/aws/amazon-cloudwatch-agent/logs/amazon-cloudwatch-agent.log
```

**Alarms not triggering:**
```bash
# Check alarm configuration
aws cloudwatch describe-alarms --alarm-names moodle-high-cpu

# Check SNS subscription
aws sns list-subscriptions-by-topic \
    --topic-arn arn:aws:sns:us-east-1:ACCOUNT:moodle-alerts

# Test SNS
aws sns publish \
    --topic-arn arn:aws:sns:us-east-1:ACCOUNT:moodle-alerts \
    --message "Test alert"
```

### Expected output

```
✓ CloudWatch Agent installed and configured
✓ Custom metrics collection enabled
✓ Log aggregation configured (5 log sources)
✓ SNS topic created: moodle-alerts
✓ Email subscription confirmed
✓ 6 alarms configured:
  - High CPU (>80%)
  - High Memory (>85%)
  - Low Disk Space (<15%)
  - Service Down
  - SSL Certificate Expiring (<30 days)
  - Moodle Cron Not Running (>10 minutes)
✓ Health check script configured (runs every 5 minutes)
✓ CloudWatch dashboard created: Moodle-Production

Monitoring active for:
  - System: CPU, Memory, Disk, Network, Swap
  - Services: Apache, PHP-FPM, Database
  - Application: Moodle cron, Active users, Response time
  - Logs: Apache, PHP-FPM, Moodle, System

View dashboard:
  https://console.aws.amazon.com/cloudwatch/dashboards/Moodle-Production

Estimated cost: ~$10/month
```

## Example usage

**User:** "Set up monitoring for my Moodle server with email alerts for critical issues."

**Assistant:** I'll configure comprehensive CloudWatch monitoring with email alerts.

[Installs CloudWatch Agent]
[Configures custom metrics for CPU, memory, disk]
[Sets up log aggregation for Apache, PHP-FPM, Moodle]
[Creates SNS topic]
[Subscribes user email]
[Creates 6 critical alarms]
[Sets up health check script]
[Creates CloudWatch dashboard]
[Tests monitoring]

Monitoring configured successfully!

**Active monitoring:**
- System metrics: CPU, Memory, Disk, Network (collected every 60s)
- Service health: Apache, PHP-FPM, Database (checked every 5 minutes)
- Logs: Real-time aggregation from 5 sources

**Alarms configured:**
1. High CPU (>80% for 5 min) → Email alert
2. High Memory (>85% for 5 min) → Email alert
3. Low Disk Space (<15%) → Email alert
4. Service Down (2 consecutive failures) → Email alert
5. SSL Expiring (<30 days) → Email alert
6. Cron Not Running (>10 minutes) → Email alert

**Email alerts sent to:** admin@yourdomain.com

**Dashboard:** [https://console.aws.amazon.com/cloudwatch/dashboards/Moodle-Production](https://console.aws.amazon.com/cloudwatch/dashboards/Moodle-Production)

Check your email to confirm the SNS subscription, then you'll receive alerts for any issues!

---

**User:** "I'm not receiving any metrics in CloudWatch. Can you troubleshoot?"

**Assistant:** Let me troubleshoot the CloudWatch monitoring.

[Checks CloudWatch Agent status]
[Reviews agent logs]
[Tests IAM permissions]

I found the issue: The IAM role attached to your EC2 instance doesn't have CloudWatch permissions.

**Problem:** Missing IAM policy for CloudWatch PutMetricData and Logs.

**Fixing:**
[Creates IAM policy with required permissions]
[Attaches policy to instance role]
[Restarts CloudWatch Agent]
[Tests metric submission]

Fixed! The agent is now sending metrics.

**Verification:**
- Metrics appearing in CloudWatch: ✓
- Logs flowing to log groups: ✓
- Test metric submitted successfully: ✓

**Current metrics visible:**
- CPU: 15%
- Memory: 45%
- Disk: 32%
- PHP-FPM Processes: 8

Your dashboard should now populate with data within 2-3 minutes!
