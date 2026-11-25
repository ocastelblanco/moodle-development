#!/bin/bash
# Recomputes PHP-FPM pool sizing after an instance type change.
# Same formula as scripts/05-optimize-system.sh.
set -euo pipefail
PHP_FPM_CONF=/etc/php-fpm.d/www.conf
TOTAL_RAM_MB=$(free -m | awk '/^Mem:/{print $2}')
SYSTEM_RAM_MB=800
MEMORY_PER_PROCESS=200
MAX_CHILDREN=$(((TOTAL_RAM_MB - SYSTEM_RAM_MB) / MEMORY_PER_PROCESS))
[[ $MAX_CHILDREN -lt 5 ]] && MAX_CHILDREN=5
[[ $MAX_CHILDREN -gt 100 ]] && MAX_CHILDREN=100
START_SERVERS=$((MAX_CHILDREN / 5)); [[ $START_SERVERS -lt 2 ]] && START_SERVERS=2
MIN_SPARE=$((MAX_CHILDREN / 7)); [[ $MIN_SPARE -lt 1 ]] && MIN_SPARE=1
MAX_SPARE=$((MAX_CHILDREN / 3)); [[ $MAX_SPARE -lt 3 ]] && MAX_SPARE=3
sed -i "s/^pm.max_children = .*/pm.max_children = $MAX_CHILDREN/" "$PHP_FPM_CONF"
sed -i "s/^pm.start_servers = .*/pm.start_servers = $START_SERVERS/" "$PHP_FPM_CONF"
sed -i "s/^pm.min_spare_servers = .*/pm.min_spare_servers = $MIN_SPARE/" "$PHP_FPM_CONF"
sed -i "s/^pm.max_spare_servers = .*/pm.max_spare_servers = $MAX_SPARE/" "$PHP_FPM_CONF"
systemctl restart php-fpm
systemctl is-active --quiet php-fpm
echo "RAM=${TOTAL_RAM_MB}MB pm.max_children=$MAX_CHILDREN start=$START_SERVERS min_spare=$MIN_SPARE max_spare=$MAX_SPARE"
