# Mantenimiento de Moodle 5.1

Guía completa de mantenimiento preventivo y resolución de problemas.

## 📋 Rutinas de Mantenimiento

### Diarias (Automáticas)

✅ **Backups de Base de Datos**
- Script: `/usr/local/bin/moodle-backup-db.sh`
- Horario: 3:00 AM
- Retención: 7 días
- Ubicación: `/var/backups/moodle/database/`

✅ **Cron de Moodle**
- Frecuencia: Cada minuto
- Monitoreo: Verificar `/var/log/cron`

✅ **Monitoreo de Memoria**
- Script: `/usr/local/bin/memory-monitor.sh`
- Frecuencia: Cada hora
- Log: `/var/log/memory-monitor.log`

### Semanales

✅ **Revisar Logs de Error**
```bash
# Apache errors
sudo tail -100 /var/log/httpd/moodle-error.log

# PHP-FPM errors
sudo tail -100 /var/log/php-fpm/error.log

# System errors
sudo journalctl -p err -S "1 week ago"
```

✅ **Verificar Espacio en Disco**
```bash
# Disk usage
df -h

# Largest directories in moodledata
sudo du -sh /moodledata/*  | sort -h | tail -10

# Clean old logs
sudo find /var/log -name "*.log.*.gz" -mtime +30 -delete
```

✅ **Revisar Actualizaciones**
```bash
# System updates
sudo dnf check-update

# Moodle updates
sudo -u apache php /var/www/html/moodle/admin/cli/check_database_schema.php
```

### Mensuales

✅ **Actualizar Sistema Operativo**
```bash
# Create snapshot first!
sudo dnf update -y
sudo reboot
```

✅ **Revisar Certificado SSL**
```bash
# Check expiry
sudo certbot certificates

# Test renewal
sudo certbot renew --dry-run
```

✅ **Optimizar Base de Datos**
```bash
# Optimize tables
mysql -h $DB_HOST -u $DB_USER -p$DB_PASSWORD $DB_NAME -e "OPTIMIZE TABLE mdl_sessions;"

# Purge old sessions
sudo -u apache php /var/www/html/moodle/admin/cli/cron.php --execute='\core\task\session_cleanup_task'
```

✅ **Revisar Plugins**
```bash
# Check for updates
# Site administration → Server → Notifications
# Site administration → Plugins → Plugins overview
```

## 🔧 Tareas de Optimización

### Limpiar Cache

```bash
# Purge all caches
sudo -u apache php /var/www/html/moodle/admin/cli/purge_caches.php

# Clear specific caches
sudo -u apache php /var/www/html/moodle/admin/cli/purge_caches.php --all
```

### Limpiar Sesiones Antiguas

```bash
# Via CLI
sudo -u apache php /var/www/html/moodle/admin/cli/cron.php --execute='\core\task\session_cleanup_task'

# Manual cleanup (si necesario)
mysql -h $DB_HOST -u $DB_USER -p$DB_PASSWORD $DB_NAME -e "DELETE FROM mdl_sessions WHERE timemodified < UNIX_TIMESTAMP(DATE_SUB(NOW(), INTERVAL 2 DAY));"
```

### Limpiar Papelera

```bash
# Clean deleted files (after 4 days default)
sudo -u apache php /var/www/html/moodle/admin/cli/cron.php --execute='\core\task\file_trash_cleanup_task'
```

## 🔄 Actualizaciones de Moodle

### Actualización Minor (5.1.0 → 5.1.1)

```bash
# 1. Backup first!
sudo /usr/local/bin/moodle-backup-db.sh
sudo tar -czf /var/backups/moodle-code-$(date +%Y%m%d).tar.gz /var/www/html/moodle

# 2. Enable maintenance mode
sudo -u apache php /var/www/html/moodle/admin/cli/maintenance.php --enable

# 3. Update code
cd /var/www/html/moodle
sudo -u apache git fetch origin
sudo -u apache git checkout MOODLE_51_STABLE
sudo -u apache git pull

# 4. Run upgrade
sudo -u apache php /var/www/html/moodle/admin/cli/upgrade.php --non-interactive

# 5. Purge caches
sudo -u apache php /var/www/html/moodle/admin/cli/purge_caches.php

# 6. Disable maintenance mode
sudo -u apache php /var/www/html/moodle/admin/cli/maintenance.php --disable
```

### Actualización Major (5.1 → 5.2)

**⚠️ IMPORTANTE:** Probar en staging primero

```bash
# Similar process but:
# - Review compatibility of plugins
# - Check system requirements
# - Plan downtime window
# - Have rollback plan ready
```

## 🚨 Troubleshooting

### Sitio Lento

**Diagnóstico:**
```bash
# Check CPU and memory
top
free -h

# Check disk I/O
iostat -x 1 5

# Check Apache/PHP processes
ps aux | grep -E 'httpd|php-fpm' | wc -l

# Check database connections
mysql -h $DB_HOST -u $DB_USER -p$DB_PASSWORD -e "SHOW PROCESSLIST;"
```

**Soluciones:**
1. Purge caches
2. Check PHP-FPM max_children
3. Optimize database queries
4. Enable Moodle caching
5. Consider CDN

### Errores 503 Service Unavailable

**Causa común:** PHP-FPM not running

```bash
# Check status
sudo systemctl status php-fpm

# Restart
sudo systemctl restart php-fpm

# Check logs
sudo tail -50 /var/log/php-fpm/error.log

# Check for OOM kills
sudo dmesg | grep -i "out of memory"
```

### Base de Datos No Responde

```bash
# Check RDS status
aws rds describe-db-instances --db-instance-identifier acgdb

# Test connection
mysql -h $DB_HOST -u $DB_USER -p$DB_PASSWORD -e "SELECT 1;"

# Check security group
# Verify EC2 security group can access RDS port 3306
```

### Cron No Se Ejecuta

```bash
# Check cron configuration
cat /etc/cron.d/moodle

# Check cron service
sudo systemctl status crond

# Check cron logs
sudo tail -f /var/log/cron

# Run manually
sudo -u apache /usr/bin/php /var/www/html/moodle/admin/cli/cron.php
```

### Certificado SSL Expirado

```bash
# Check expiry
sudo certbot certificates

# Renew immediately
sudo certbot renew --force-renewal

# Restart Apache
sudo systemctl restart httpd
```

## 📊 Monitoreo de Salud

### Script de Verificación Rápida

```bash
sudo /usr/local/bin/moodle-status.sh
```

### Health Check Completo

```bash
sudo /usr/local/bin/moodle-health-check.sh
```

### CloudWatch Metrics

```bash
# View in AWS Console
# CloudWatch → Dashboards → Moodle

# Or via CLI
aws cloudwatch get-metric-statistics \
    --namespace Moodle/EC2 \
    --metric-name MEMORY_USED \
    --dimensions Name=InstanceId,Value=i-xxxxx \
    --start-time $(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%S) \
    --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
    --period 300 \
    --statistics Average
```

## 💾 Recuperación de Desastres

### Restaurar desde Backup

**Base de Datos:**
```bash
# Find backup
ls -lh /var/backups/moodle/database/

# Restore
gunzip < /var/backups/moodle/database/moodle-db-YYYYMMDD.sql.gz | \
    mysql -h $DB_HOST -u $DB_USER -p$DB_PASSWORD $DB_NAME
```

**Moodledata:**
```bash
# Restore
sudo tar -xzf /var/backups/moodle/moodledata/moodledata-YYYYMMDD.tar.gz -C /
```

**Código:**
```bash
# Via Git
cd /var/www/html/moodle
sudo -u apache git checkout <commit-hash>

# From backup
sudo tar -xzf /var/backups/moodle-code-YYYYMMDD.tar.gz -C /var/www/html/
```

### Rollback de Actualización

```bash
# 1. Enable maintenance mode
sudo -u apache php /var/www/html/moodle/admin/cli/maintenance.php --enable

# 2. Restore database
gunzip < /path/to/backup.sql.gz | mysql -h $DB_HOST -u $DB_USER -p$DB_PASSWORD $DB_NAME

# 3. Restore code
cd /var/www/html/moodle
sudo -u apache git checkout <previous-version>

# 4. Fix permissions
sudo chown -R apache:apache /var/www/html/moodle

# 5. Purge caches
sudo -u apache php /var/www/html/moodle/admin/cli/purge_caches.php

# 6. Disable maintenance mode
sudo -u apache php /var/www/html/moodle/admin/cli/maintenance.php --disable
```

## 📈 Métricas de Performance

### Comandos Útiles

```bash
# Apache connections
sudo netstat -ant | grep :80 | grep ESTABLISHED | wc -l

# PHP-FPM processes
ps aux | grep php-fpm | grep -v grep | wc -l

# Database connections
mysql -h $DB_HOST -u $DB_USER -p$DB_PASSWORD -e "SHOW STATUS LIKE 'Threads_connected';"

# Disk I/O
iostat -x 1 5

# Load average
uptime

# Memory usage
free -h
```

### Logs Importantes

```
/var/log/httpd/moodle-access.log    - Apache access
/var/log/httpd/moodle-error.log     - Apache errors
/var/log/php-fpm/error.log          - PHP errors
/var/log/memory-monitor.log         - Memory usage
/var/log/moodle-backup.log          - Backup status
/var/log/cron                       - Cron execution
```

## 🔒 Seguridad

### Auditoría Mensual

```bash
# Failed login attempts
# Check in Moodle: Reports → Logs

# System updates
sudo dnf check-update | grep -i security

# Open ports
sudo netstat -tuln

# Review users with shell access
cat /etc/passwd | grep -v nologin
```

### Hardening Checklist

- [ ] Firewall configurado (solo 22, 80, 443)
- [ ] SSH key-only (no passwords)
- [ ] SSL certificate válido y actualizado
- [ ] Moodle actualizado a última versión
- [ ] Plugins actualizados
- [ ] Strong password policy enabled
- [ ] Admin password rotated regularly
- [ ] Backups funcionando y verificados
- [ ] Monitoring activo

## 📞 Contactos de Emergencia

```
AWS Support: https://console.aws.amazon.com/support/
Moodle Community: https://moodle.org/mod/forum/
Security Issues: security@moodle.org
```

## ✅ Checklist de Mantenimiento

### Diario
- [ ] Revisar alertas CloudWatch
- [ ] Verificar backups completados

### Semanal
- [ ] Revisar logs de error
- [ ] Verificar espacio en disco
- [ ] Check SSL certificate status

### Mensual
- [ ] Actualizar sistema operativo
- [ ] Revisar y aplicar actualizaciones de Moodle
- [ ] Optimizar base de datos
- [ ] Test backup restore
- [ ] Security audit

---

**Fecha:** 2026-02-02
**Versión:** 1.0.0
