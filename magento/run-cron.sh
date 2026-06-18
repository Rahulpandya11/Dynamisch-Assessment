#!/bin/bash
set -e
echo "[CRON] Starting Magento cron daemon..."
while true; do
  echo "[CRON] $(date) — running cron groups"
  php /var/www/html/bin/magento cron:run --group="default" 2>&1 || true
  php /var/www/html/bin/magento cron:run --group="index" 2>&1 || true
  php /var/www/html/bin/magento cron:run --group="ddg_automation" 2>&1 || true
  sleep 60
done
