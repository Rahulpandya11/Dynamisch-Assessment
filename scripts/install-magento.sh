#!/bin/bash
set -euo pipefail

set -a
source /opt/magento/secrets/.env
set +a

COMPOSE="docker compose --env-file /opt/magento/secrets/.env -f /opt/magento/docker-compose.yml"
cd /opt/magento

echo "=== Building images ==="
$COMPOSE build

echo "=== Starting dependencies ==="
$COMPOSE up -d mysql redis elasticsearch

echo "=== Waiting for MySQL ==="
for i in $(seq 1 24); do
  docker exec magento_mysql mysqladmin ping -h localhost -uroot -p"${MYSQL_ROOT_PASSWORD}" --silent 2>/dev/null && echo "MySQL ready!" && break
  echo "  attempt $i/24..."; sleep 5
  if [ $i -eq 24 ]; then echo "ERROR: MySQL never ready"; exit 1; fi
done

echo "=== Waiting for Elasticsearch ==="
for i in $(seq 1 48); do
  STATUS=$(docker exec magento_elasticsearch curl -sf http://localhost:9200/_cluster/health 2>/dev/null || echo "")
  if echo "$STATUS" | grep -q '"status"'; then echo "ES ready!"; break; fi
  echo "  attempt $i/48..."; sleep 5
  if [ $i -eq 48 ]; then echo "ERROR: ES never ready"; exit 1; fi
done

echo "=== Magento install ==="
$COMPOSE run --rm --user 1001:1001 \
  -e COMPOSER_HOME=/var/www/html/var/composer_home \
  php-fpm bash -c "
  cd /var/www/html && \
  php bin/magento setup:install \
    --base-url=https://test.dyna.com/ \
    --base-url-secure=https://test.dyna.com/ \
    --db-host=mysql \
    --db-name=${MYSQL_DATABASE} \
    --db-user=${MYSQL_USER} \
    --db-password='${MYSQL_PASSWORD}' \
    --admin-firstname=${MAGENTO_ADMIN_FIRSTNAME} \
    --admin-lastname=${MAGENTO_ADMIN_LASTNAME} \
    --admin-email=${MAGENTO_ADMIN_EMAIL} \
    --admin-user=${MAGENTO_ADMIN_USER} \
    --admin-password='${MAGENTO_ADMIN_PASSWORD}' \
    --backend-frontname=${MAGENTO_ADMIN_URI} \
    --language=en_US \
    --currency=USD \
    --timezone=America/Chicago \
    --use-rewrites=1 \
    --use-secure=1 \
    --use-secure-admin=1 \
    --search-engine=elasticsearch7 \
    --elasticsearch-host=elasticsearch \
    --elasticsearch-port=9200 \
    --session-save=redis \
    --session-save-redis-host=redis \
    --session-save-redis-password='${REDIS_PASSWORD}' \
    --session-save-redis-port=6379 \
    --session-save-redis-db=2 \
    --cache-backend=redis \
    --cache-backend-redis-server=redis \
    --cache-backend-redis-password='${REDIS_PASSWORD}' \
    --cache-backend-redis-port=6379 \
    --cache-backend-redis-db=0 \
    --page-cache=redis \
    --page-cache-redis-server=redis \
    --page-cache-redis-password='${REDIS_PASSWORD}' \
    --page-cache-redis-port=6379 \
    --page-cache-redis-db=1
"

echo "=== Sample data ==="
$COMPOSE run --rm --user 1001:1001 \
  -e COMPOSER_HOME=/var/www/html/var/composer_home \
  php-fpm bash -c "
  cd /var/www/html && \
  php bin/magento sampledata:deploy && \
  php bin/magento setup:upgrade && \
  php bin/magento setup:di:compile && \
  php bin/magento setup:static-content:deploy -f en_US && \
  php bin/magento indexer:reindex && \
  php bin/magento cache:flush
"

echo "=== Configure Varnish ==="
$COMPOSE run --rm --user 1001:1001 \
  -e COMPOSER_HOME=/var/www/html/var/composer_home \
  php-fpm bash -c "
  cd /var/www/html && \
  php bin/magento config:set system/full_page_cache/caching_application 2 && \
  php bin/magento config:set system/full_page_cache/varnish/backend_host nginx && \
  php bin/magento config:set system/full_page_cache/varnish/backend_port 8080
"

echo "=== Set permissions ==="
$COMPOSE run --rm --user root php-fpm bash -c "
  find /var/www/html -type d -exec chmod 750 {} \; && \
  find /var/www/html -type f -exec chmod 640 {} \; && \
  chmod -R 770 /var/www/html/var /var/www/html/pub/static \
    /var/www/html/pub/media /var/www/html/generated && \
  chown -R 1001:1001 /var/www/html
"

echo "=== Starting full stack ==="
$COMPOSE up -d

echo ""
echo "✅ Done!"
echo "   Frontend : https://test.dyna.com/"
echo "   Admin    : https://test.dyna.com/dynasecure"
echo "   PMA      : https://test.dyna.com/pma/"
