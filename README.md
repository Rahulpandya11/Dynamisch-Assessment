# Magento 2 Production Stack — Senior DevOps Assessment

Production-grade Magento 2.4.7-p3 deployment on AWS EC2, fully containerised
with Docker Compose. Eight dedicated containers, each with a single
responsibility, running as a non-root user matching the host uid/gid.

---

## AWS Infrastructure

| Parameter      | Value                                  |
|----------------|----------------------------------------|
| Region         | ap-south-1 (Mumbai)                    |
| Instance type  | t3.small                               |
| AMI            | Ubuntu 26.04 LTS ami-01a00762f46d584a1 |
| Storage        | 25 GB gp3 EBS                          |
| Elastic IP     | 13.205.76.100                          |
| Security Group | 22/TCP, 80/TCP, 443/TCP                |

### Hosts file entry for reviewer machine

```
13.205.76.100  test.dyna.com
```

**Windows (PowerShell as Administrator):**
```powershell
Add-Content -Path "C:\Windows\System32\drivers\etc\hosts" -Value "13.205.76.100  test.dyna.com"
```

**Mac / Linux:**
```bash
echo "13.205.76.100  test.dyna.com" | sudo tee -a /etc/hosts
```

---

## Deviations from Spec

| Requirement          | Actual        | Reason                                                                          |
|----------------------|---------------|---------------------------------------------------------------------------------|
| t3.micro             | t3.small      | Magento `setup:di:compile` OOM-kills on 1 GB RAM; t3.small provides 2 GB       |
| Debian 12            | Ubuntu 26.04  | Broader AWS AMI availability in ap-south-1; identical Docker behaviour          |
| Magento 2.4.9 latest | 2.4.7-p3      | 2.4.9 requires PHP 8.3+; spec mandates PHP 8.2; 2.4.7-p3 is latest PHP 8.2 release |
| Named volumes var/pub| Bind mounts   | Named volumes created root-owned stub dirs obscuring Magento files on bind-mount |
| `internal: true`     | Standard bridge | `sampledata:deploy` requires outbound internet during one-time installation    |

---

## Security Group Justification

| Port    | Justification                                                     |
|---------|-------------------------------------------------------------------|
| 22/TCP  | SSH — key-based only, password authentication disabled in sshd    |
| 80/TCP  | HTTP — 301 permanent redirect to HTTPS; no content served on HTTP |
| 443/TCP | HTTPS — all storefront, admin, media and static file traffic      |

All internal service ports (MySQL 3306, Redis 6379, Elasticsearch 9200,
PHP-FPM 9000, Varnish 6081, phpMyAdmin 80) are on the Docker internal bridge
network. They are never bound to the host network interface and are unreachable
from the internet.

---

## Container Architecture

| Container              | Image                    | Role                                     |
|------------------------|--------------------------|------------------------------------------|
| magento_nginx          | magento_nginx:local      | TLS termination, HTTP/2, reverse proxy   |
| magento_varnish        | magento_varnish:local    | Full-page HTTP cache (Varnish 7.5)       |
| magento_phpfpm         | magento_phpfpm:local     | Magento 2 application (PHP-FPM 8.2)      |
| magento_cron           | magento_phpfpm:local     | Magento cron — all 3 groups              |
| magento_mysql          | mysql:8.0.36             | Relational database                      |
| magento_elasticsearch  | elasticsearch:7.17.20    | Catalog search engine                    |
| magento_redis          | redis:8.0-alpine         | Cache (db0), page cache (db1), sessions (db2) |
| magento_phpmyadmin     | phpmyadmin:5.2-apache    | Database management UI                   |

---

## Quick Start — Reproducing on a Fresh EC2

### 1. Bootstrap the host (Docker, swap, firewall, user/group)

```bash
sudo bash scripts/provision-host.sh
```

### 2. Clone the repository

```bash
git clone https://github.com/Rahulpandya11/Dynamisch-Assessment.git /opt/magento
cd /opt/magento
```

### 3. Create the secrets file

```bash
cp secrets/.env.example secrets/.env
vim secrets/.env        # fill in all values — never commit this file
```

### 4. Add Magento Marketplace credentials

Get keys from https://commercemarketplace.adobe.com → My Profile → Access Keys.

```bash
mkdir -p magento/app/var/composer_home
cat > magento/app/var/composer_home/auth.json <<'EOF'
{
    "http-basic": {
        "repo.magento.com": {
            "username": "YOUR_PUBLIC_KEY",
            "password": "YOUR_PRIVATE_KEY"
        }
    }
}
EOF
chown -R 1001:1001 magento/app/
```

### 5. Install Magento via Composer (one-time, ~15 min)

```bash
docker build -t magento_phpfpm:local ./magento

docker run --rm \
  --user 1001:1001 \
  -v /opt/magento/magento/app:/var/www/html \
  -v /opt/magento/magento/app/var/composer_home:/tmp/composer \
  -e COMPOSER_HOME=/tmp/composer \
  magento_phpfpm:local \
  bash -c "cd /var/www/html && composer create-project \
    --repository-url=https://repo.magento.com/ \
    magento/project-community-edition=2.4.7-p3 . --no-interaction"
```

### 6. Run the full installation

```bash
make install
```

This builds all images, starts dependencies, runs `setup:install`, deploys
sample data, compiles DI, deploys static content, reindexes, configures
Varnish as FPC, sets permissions, and starts the full stack.

---

## Access Details

| Service    | URL                              | Notes                              |
|------------|----------------------------------|------------------------------------|
| Storefront | https://test.dyna.com/           | Accept self-signed cert warning    |
| Admin      | https://test.dyna.com/dynasecure | Credentials sent out-of-band       |
| phpMyAdmin | https://test.dyna.com/pma/       | HTTP Basic Auth prompt appears first |

---

## Resource Tuning Decisions

### Elasticsearch heap: 128 MB (`-Xms128m -Xmx128m`)

Minimum viable for single-node Magento catalog search. Setting Xms equal to
Xmx prevents heap resizing pauses at runtime. The GeoIP downloader plugin is
effectively disabled (no outbound access from internal network in production)
saving ~50 MB RSS.

### MySQL InnoDB buffer pool: 256 MB

Approximately 64% of the 400 MB container memory limit — standard InnoDB
guidance for a dedicated instance. `innodb_flush_log_at_trx_commit=2` trades
strict per-transaction fsync for throughput; acceptable for a non-financial
workload. `performance_schema=OFF` saves ~100 MB RSS on a constrained host.

### PHP-FPM pool tuning

```ini
pm = dynamic
pm.max_children      = 6    # 6 × ~50 MB RSS = 300 MB, fits inside 512 MB limit
pm.start_servers     = 2    # Pre-warm two workers to absorb initial traffic
pm.min_spare_servers = 1    # Always keep one idle worker ready
pm.max_spare_servers = 3    # Release workers when traffic drops
pm.max_requests      = 500  # Recycle to prevent memory leaks accumulating
```

Each PHP-FPM child under Magento load consumes approximately 50 MB RSS.
OPcache occupies an additional 128 MB shared across all workers. The container
memory limit of 512 MB accommodates both with headroom for the master process.

### OPcache

```ini
opcache.memory_consumption     = 128    # Holds compiled Magento bytecode
opcache.max_accelerated_files  = 60000  # Magento ships ~50 000+ PHP files
opcache.validate_timestamps    = 0      # No stat() syscall per request in production
opcache.revalidate_freq        = 0      # Never revalidate — production setting
opcache.save_comments          = 1      # Required by Magento DI annotation parser
```

### Swap: 4 GB

`setup:di:compile` and `setup:static-content:deploy` spike resident memory
beyond 2 GB during the one-time install. Swap prevents OOM kills during these
operations. `vm.swappiness=10` keeps swap as a last resort during normal runtime.

### Redis: 128 MB maxmemory, allkeys-lru eviction

Bounded memory prevents Redis from consuming unbounded RAM. LRU eviction is
appropriate because Magento cache keys carry explicit TTLs — least-recently-used
entries are the safest to evict. Three logical databases isolate concerns:

| DB | Purpose      |
|----|--------------|
| 0  | Default cache |
| 1  | Full-page cache |
| 2  | Sessions |

---

## Redis Configuration (app/etc/env.php — secrets redacted)

```php
'cache' => [
    'frontend' => [
        'default' => [
            'backend' => 'Magento\\Framework\\Cache\\Backend\\Redis',
            'backend_options' => [
                'server'   => 'redis',
                'port'     => '6379',
                'database' => '0',
                'password' => '******',
            ],
        ],
        'page_cache' => [
            'backend' => 'Magento\\Framework\\Cache\\Backend\\Redis',
            'backend_options' => [
                'server'   => 'redis',
                'port'     => '6379',
                'database' => '1',
                'password' => '******',
            ],
        ],
    ],
],
'session' => [
    'save' => 'redis',
    'redis' => [
        'host'     => 'redis',
        'port'     => '6379',
        'password' => '******',
        'database' => '2',
    ],
],
```

---

## TLS Certificate

Self-signed certificate with Subject Alternative Name:

```bash
openssl req -x509 -nodes -days 365 \
  -newkey rsa:2048 \
  -keyout nginx/ssl/test.dyna.com.key \
  -out    nginx/ssl/test.dyna.com.crt \
  -subj "/C=US/ST=State/L=City/O=Dyna/CN=test.dyna.com" \
  -addext "subjectAltName=DNS:test.dyna.com,DNS:www.test.dyna.com"
```

- Protocols: TLS 1.2 and TLS 1.3 only
- Cipher suite: ECDHE+AES-GCM and ECDHE+CHACHA20 (forward secrecy)
- HTTP/2 enabled on port 443
- HSTS header: `max-age=31536000`
- Private key committed to `.gitignore` — never enters the repository

---

## Filesystem Permissions

```
Directories         : 750  (rwxr-x---)
Files               : 640  (rw-r-----)
Writable dirs       : 770  — var/  pub/static/  pub/media/  generated/
Owner               : test-ssh:clp  (uid 1001 / gid 1001)
```

Permissions survive container rebuild because all Magento application files
live on a host bind-mount (`magento/app/`). The Dockerfile creates the
matching uid/gid inside the image at build time. A privileged permission pass
during `make install` sets ownership to `1001:1001` on the host filesystem.
Subsequent container rebuilds inherit those numeric ids from the image without
touching the host files.

---

## Varnish Cache Verification

```bash
# First request — cache MISS (cold)
curl -kI https://test.dyna.com/women.html
# x-varnish-cache: MISS
# via: 1.1 Varnish/7.5

# Second request — cache HIT (served from Varnish memory)
curl -kI https://test.dyna.com/women.html
# x-varnish-cache: HIT
# via: 1.1 Varnish/7.5
```

---

## Cron Verification

```bash
docker logs magento_cron
# [CRON] Thu Jun 18 18:11:12 UTC 2026 — running cron groups
# Ran jobs by schedule.   <- default group
# Ran jobs by schedule.   <- index group
# Ran jobs by schedule.   <- ddg_automation group
```

Three cron groups (`default`, `index`, `ddg_automation`) run every 60 seconds
inside a dedicated container that shares the application bind-mount.

---

## Data Persistence Test

```bash
docker compose --env-file secrets/.env down
docker compose --env-file secrets/.env up -d

# MySQL data    — named volume magento_mysql_data          — survives
# ES data       — named volume magento_elasticsearch_data  — survives
# Magento code  — host bind-mount magento/app/             — survives
# Media files   — host bind-mount magento/app/pub/media/   — survives
```

After restart the storefront returns HTTP 200 and the admin session requires
re-login (expected — session store is Redis which also persists via bind-mount).

---

## Acceptance Test Results

| # | Test | Result |
|---|------|--------|
| 1 | `curl -I http://test.dyna.com/` returns 301 | PASS |
| 2 | `https://test.dyna.com/` loads storefront with sample data | PASS |
| 3 | Category page returns Varnish HIT on second request | PASS |
| 4 | Admin login works, URL is `/dynasecure` not `/admin` | PASS |
| 5 | phpMyAdmin requires HTTP Basic Auth before login screen | PASS |
| 6 | `whoami` inside container returns `test-ssh`, group `clp` | PASS |
| 7 | `down` then `up` preserves database and media files | PASS |
| 8 | Redis CLI shows keys in db0 (cache) and db2 (sessions) | PASS |

---

## Known Limitations

- Redis db1 (page_cache) keys appear only after Varnish passes a request
  through to PHP-FPM on a cache MISS and Magento writes the FPC entry. On a
  warm Varnish cache, Magento's Redis FPC is bypassed entirely — which is the
  correct behaviour (Varnish serves before reaching PHP).
- The `internal: true` Docker network flag was removed to allow
  `sampledata:deploy` to reach repo.magento.com during installation. In a
  production hardening pass this would be replaced with an egress proxy or
  pre-downloaded sample data package.
- Self-signed TLS certificate causes browser security warnings. In production
  this would be replaced with a Let's Encrypt certificate via Certbot or
  AWS Certificate Manager.

---

## Repository Structure

```
.
├── docker-compose.yml            All 8 services, networks, volumes, healthchecks
├── Makefile                      make install / start / stop / logs / shell
├── README.md                     This file
├── .gitignore                    Excludes secrets, pem keys, vendor, generated
├── magento/
│   ├── Dockerfile                PHP-FPM 8.2 runtime — non-root user test-ssh
│   └── run-cron.sh               Loops 3 Magento cron groups every 60 s
├── nginx/
│   ├── Dockerfile                Runs as test-ssh:clp
│   ├── conf.d/
│   │   └── magento.conf          TLS vhost + 301 redirect + Varnish proxy + PMA
│   ├── ssl/
│   │   └── test.dyna.com.crt     Self-signed cert with SAN (key is git-ignored)
│   └── auth/
│       └── .htpasswd             phpMyAdmin HTTP Basic Auth (git-ignored)
├── varnish/
│   ├── Dockerfile                Varnish 7.5-alpine
│   └── default.vcl               Magento 2 VCL with HIT/MISS debug headers
├── mysql/
│   └── my.cnf                    InnoDB tuning for low-RAM environment
├── php-fpm/
│   ├── www.conf                  Pool: test-ssh:clp, dynamic pm, tuned children
│   └── magento.ini               OPcache, memory_limit=756M, timeouts
└── scripts/
    ├── provision-host.sh         Bootstraps fresh EC2: Docker, swap, UFW, user
    └── install-magento.sh        Full Magento install orchestration script
```
