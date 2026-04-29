# Deployment Guide

Full-stack deployment of **Incenva Rebate Finder** (Next.js app) and **Incenva Scraper Service** (Go) on a single **Ubuntu 22.04 LTS** VPS.

All application processes run under a dedicated `rf` system user. Commands that require `root` privileges are marked with `# run as root` or use `sudo`.

---

## Table of Contents

1. [Architecture overview](#1-architecture-overview)
2. [Automated setup (recommended)](#2-automated-setup-recommended)
3. [Manual setup](#3-manual-setup)
   - 3.1 [System user](#31-system-user)
   - 3.2 [Node.js 20 LTS](#32-nodejs-20-lts)
   - 3.3 [pnpm](#33-pnpm)
   - 3.4 [Go 1.24](#34-go-124)
   - 3.5 [PostgreSQL 16](#35-postgresql-16)
   - 3.6 [Redis (optional)](#36-redis-optional)
   - 3.7 [PM2](#37-pm2)
   - 3.8 [Nginx](#38-nginx)
   - 3.9 [Firewall](#39-firewall)
4. [Database setup](#4-database-setup)
5. [Deploy the main app](#5-deploy-the-main-app)
6. [Deploy the scraper service](#6-deploy-the-scraper-service)
7. [Nginx + SSL](#7-nginx--ssl)
8. [PM2 startup on reboot](#8-pm2-startup-on-reboot)
9. [Deploying updates](#9-deploying-updates)
10. [Admin users](#10-admin-users)
11. [Useful commands](#11-useful-commands)
12. [Troubleshooting](#12-troubleshooting)
13. [Appendix: Scraper systemd unit](#appendix-scraper-systemd-unit)

---

## 1. Architecture overview

```
Internet
    │
    ▼
 Nginx :443 (SSL)   ←─── Certbot (auto-renews Let's Encrypt cert)
    │
    ▼
 Next.js  :3000     ←─── PM2 "Rebate Finder"   (rf user)
    │
    ├── Prisma ──► PostgreSQL :5432 (local)
    └── Supabase (remote storage / auth)

 Go Scraper          ←─── PM2 "Incenva Scraper" (rf user)
    └── GORM   ──► PostgreSQL :5432 (same DB, scraper.rebates_staging)

 Go Promoter         ←─── PM2 "incenva-promoter" (hourly cron, rf user)
    └── GORM   ──► PostgreSQL :5432 (reads scraper.*, writes public.rebates)
```

Both apps share the same local PostgreSQL database via `DATABASE_URL`.
The Go scraper owns the `scraper` schema; Prisma (Next.js) owns the `public` schema.
`prisma db push` never touches `scraper.*` tables — they are invisible to it.

---

## 2. Automated setup (recommended)

The fastest path on a fresh Ubuntu 22.04 server. Each script is **idempotent** — safe to run multiple times.

### 2.0 Set up GitHub deploy keys (first time only)

Before cloning anything, you need SSH deploy keys configured so the `rf` user can pull from GitHub without a password.

**→ Follow the complete guide: [docs/github-deploy-keys.md](./github-deploy-keys.md)**

The short version — run this block as root, then add the three printed public keys to their respective repos on GitHub:

```bash
mkdir -p /home/rf/.ssh && chmod 700 /home/rf/.ssh
ssh-keygen -t ed25519 -C "rf@server:rebate-finder"             -f /home/rf/.ssh/id_ed25519_rebate_finder             -N ""
ssh-keygen -t ed25519 -C "rf@server:rebate-finder-scrapers"    -f /home/rf/.ssh/id_ed25519_rebate_finder_scrapers    -N ""
ssh-keygen -t ed25519 -C "rf@server:rebate-finder-deployement" -f /home/rf/.ssh/id_ed25519_rebate_finder_deployement -N ""
chown -R rf:rf /home/rf/.ssh && chmod 600 /home/rf/.ssh/id_ed25519_*
cat > /home/rf/.ssh/config << 'EOF'
Host github-rebate-finder
    HostName github.com
    User git
    IdentityFile /home/rf/.ssh/id_ed25519_rebate_finder
    IdentitiesOnly yes
Host github-rebate-finder-scrapers
    HostName github.com
    User git
    IdentityFile /home/rf/.ssh/id_ed25519_rebate_finder_scrapers
    IdentitiesOnly yes
Host github-rebate-finder-deployement
    HostName github.com
    User git
    IdentityFile /home/rf/.ssh/id_ed25519_rebate_finder_deployement
    IdentitiesOnly yes
EOF
chown rf:rf /home/rf/.ssh/config && chmod 600 /home/rf/.ssh/config
# Print the three public keys and add each to GitHub → Repo Settings → Deploy keys
cat /home/rf/.ssh/id_ed25519_rebate_finder.pub
cat /home/rf/.ssh/id_ed25519_rebate_finder_scrapers.pub
cat /home/rf/.ssh/id_ed25519_rebate_finder_deployement.pub
```

After adding the keys to GitHub, test each connection:
```bash
sudo -u rf ssh -T github-rebate-finder            # "Hi SomethingPressing/rebate-finder!"
sudo -u rf ssh -T github-rebate-finder-scrapers
sudo -u rf ssh -T github-rebate-finder-deployement
```

### 2.1 Clone this deployment repo

```bash
# run as rf user (after deploy keys are set up above)
sudo -u rf git clone \
  git@github-rebate-finder-deployement:SomethingPressing/rebate-finder-deployement.git \
  /home/rf/apps/deployment
cd /home/rf/apps/deployment
```

### 2.2 Run main app setup

```bash
# run as root
bash scripts/rebate-finder/setup-server.sh
```

What it does:
- Creates Linux `rf` user + group
- Installs Node.js 20, pnpm, PM2
- Installs PostgreSQL, creates `rf` DB role + `rebate_finder` database
- Generates `.env` with a random `JWT_SECRET` and `DATABASE_URL`
- Clones / installs the app, pushes Prisma schema, seeds the DB
- Builds the Next.js app and starts it with PM2

After it finishes, edit `.env` in the app directory:
```bash
nano /home/rf/apps/rebate-finder/.env
# → set OPENAI_API_KEY, NEXT_PUBLIC_SUPABASE_*, NEXT_BASE_URL
```

Then rebuild:
```bash
bash scripts/rebate-finder/deploy.sh
```

### 2.3 Run scraper setup

```bash
# run as root
bash scripts/scraper/setup-server.sh
```

What it does:
- Installs Go 1.22
- Builds `bin/scraper`, `bin/promoter`, `bin/pdf-scraper`, and `bin/staging-stats`
- Creates `.env` inheriting `DATABASE_URL`, `SCRAPER_DB_SCHEMA`, and `PROMOTER_SOURCE_PRIORITY` from the main app
- Starts the scheduled scraper with PM2

---

## 3. Manual setup

Follow these steps if you prefer to install each component individually.

### 3.1 System user

```bash
# run as root
adduser --disabled-password --gecos "" rf
usermod -aG sudo rf
```

Set up SSH access for the `rf` user:
```bash
mkdir -p /home/rf/.ssh
chmod 700 /home/rf/.ssh
echo "ssh-ed25519 AAAA... deployer@hostname" >> /home/rf/.ssh/authorized_keys
chmod 600 /home/rf/.ssh/authorized_keys
chown -R rf:rf /home/rf/.ssh
```

Verify:
```bash
id rf   # uid=1001(rf) gid=1001(rf) groups=1001(rf),27(sudo)
```

---

### 3.2 Node.js 20 LTS

```bash
# run as root
curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt-get install -y nodejs
node -v   # v20.x.x
```

---

### 3.3 pnpm

```bash
npm install -g pnpm
pnpm -v
```

---

### 3.4 Go 1.24

```bash
# run as root
GO_VERSION=1.24.1
curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" -o /tmp/go.tar.gz
rm -rf /usr/local/go
tar -C /usr/local -xzf /tmp/go.tar.gz
rm /tmp/go.tar.gz

echo 'export PATH=$PATH:/usr/local/go/bin' > /etc/profile.d/golang.sh
chmod +x /etc/profile.d/golang.sh
source /etc/profile.d/golang.sh

go version   # go version go1.24.1 linux/amd64
```

---

### 3.5 PostgreSQL 16

```bash
# run as root
apt-get install -y postgresql-16 postgresql-contrib
systemctl enable --now postgresql
psql --version   # psql (PostgreSQL) 16.x
```

---

### 3.6 Redis (optional)

Redis is used for rate limiting and session caching. The app works without it.

```bash
# run as root
apt-get install -y redis-server
systemctl enable --now redis-server
redis-cli ping   # PONG
```

---

### 3.7 PM2

```bash
# run as root
npm install -g pm2
```

---

### 3.8 Nginx

```bash
# run as root
apt-get install -y nginx
systemctl enable --now nginx
```

---

### 3.9 Firewall

```bash
# run as root
ufw allow OpenSSH
ufw allow 'Nginx Full'   # ports 80 + 443
ufw --force enable
ufw status
```

> **Do not** open port 3000 publicly — Nginx proxies to it internally.

---

## 4. Database setup

```bash
# run as root (or prefix with sudo)
sudo -u postgres psql <<'SQL'
CREATE DATABASE rebate_finder;
CREATE USER rf WITH PASSWORD 'choose-a-strong-password';
GRANT ALL PRIVILEGES ON DATABASE rebate_finder TO rf;
ALTER DATABASE rebate_finder OWNER TO rf;
SQL
```

Test the connection:
```bash
psql "postgresql://rf:choose-a-strong-password@localhost:5432/rebate_finder" -c "SELECT version();"
```

Save the DSN — it goes in both `.env` files:
```
DATABASE_URL=postgresql://rf:choose-a-strong-password@localhost:5432/rebate_finder
```

---

## 5. Deploy the main app

Run as the **`rf` user** (`sudo -u rf -i`):

```bash
mkdir -p /home/rf/apps
cd /home/rf/apps
git clone git@github-rebate-finder:SomethingPressing/rebate-finder.git rebate-finder
cd rebate-finder

pnpm install --frozen-lockfile
cp .env.example .env
nano .env   # fill in DATABASE_URL, JWT_SECRET, Supabase vars

pnpm prisma db push
pnpm prisma generate
pnpm db:seed       # first deploy only

pnpm build

pm2 start "pnpm start" --name "Rebate Finder"
pm2 save
```

Verify:
```bash
pm2 status
pm2 logs "Rebate Finder" --lines 20
curl http://localhost:3000   # should return HTML
```

### Required `.env` values

```env
DATABASE_URL=postgresql://rf:<password>@localhost:5432/rebate_finder
JWT_SECRET=<64-char random string>
JWT_EXPIRES_IN=24h
PORT=3000
NEXT_BASE_URL=https://rebates.yourclient.com
NEXT_PUBLIC_SUPABASE_URL=https://<project>.supabase.co
NEXT_PUBLIC_SUPABASE_ANON_KEY=eyJ...
NEXT_PUBLIC_SUPABASE_PROJECT_ID=<project-id>
SUPABASE_SERVICE_KEY=eyJ...

# Scraper schema separation — Go scraper writes to this PostgreSQL schema,
# Prisma only manages the public schema and never sees these tables.
SCRAPER_DB_SCHEMA=scraper
PROMOTER_SOURCE_PRIORITY=rewiring_america,dsireusa,energy_star
```

Generate `JWT_SECRET`:
```bash
node -e "console.log(require('crypto').randomBytes(64).toString('hex'))"
```

---

## 6. Deploy the scraper service

Run as the **`rf` user**:

```bash
cd /home/rf/apps
git clone git@github-rebate-finder-scrapers:SomethingPressing/rebate-finder-scrapers.git incenva-scraper-service
cd incenva-scraper-service

go mod download
mkdir -p bin
go build -o bin/scraper   ./cmd/scraper
go build -o bin/promoter  ./cmd/promoter
go build -o bin/pdf-scraper ./cmd/pdf-scraper

cp .env.example .env
nano .env   # set DATABASE_URL (same as main app), REWIRING_AMERICA_API_KEY

pm2 start bin/scraper \
  --name "Incenva Scraper" \
  --interpreter none \
  --cwd /home/rf/apps/incenva-scraper-service
pm2 save
```

Verify:
```bash
pm2 status
pm2 logs "Incenva Scraper" --lines 20
```

### Required `.env` values

```env
DATABASE_URL=postgresql://rf:<password>@localhost:5432/rebate_finder
REWIRING_AMERICA_API_KEY=<your-key>
RUN_ONCE=false
SCRAPER_INTERVAL=@every 6h
LOG_FORMAT=json

# Schema separation — must match the value in the main app .env
SCRAPER_DB_SCHEMA=scraper
PROMOTER_SOURCE_PRIORITY=rewiring_america,dsireusa,energy_star
```

---

## 7. Nginx + SSL

### Install the virtual host config

```bash
# run as root
cp /home/rf/deployment/nginx/rebate-finder.conf /etc/nginx/sites-available/rebate-finder
# Edit the server_name lines to match your domain
nano /etc/nginx/sites-available/rebate-finder

ln -sf /etc/nginx/sites-available/rebate-finder /etc/nginx/sites-enabled/
nginx -t
systemctl reload nginx
```

### Get an SSL certificate (Let's Encrypt)

```bash
# run as root
apt-get install -y certbot python3-certbot-nginx
certbot --nginx -d rebates.yourclient.com
```

Certbot automatically:
1. Obtains the certificate
2. Edits your Nginx config to add SSL lines
3. Sets up auto-renewal via a systemd timer

Verify auto-renewal:
```bash
certbot renew --dry-run
systemctl status certbot.timer
```

---

## 8. PM2 startup on reboot

Ensures all PM2 processes restart automatically after a server reboot:

```bash
# run as root
pm2 startup systemd -u rf --hp /home/rf
# Copy and run the command it prints
```

Then as the `rf` user:
```bash
pm2 save
```

Test: reboot the server and check `pm2 status` — both processes should be `online`.

---

## 9. Deploying updates

Use the deploy scripts for routine updates. They handle git pull, install, build, and restart.

### Main app update

```bash
# run as rf user from the deployment repo
bash scripts/rebate-finder/deploy.sh
```

Or manually:
```bash
cd /home/rf/apps/rebate-finder
git pull
pnpm install --frozen-lockfile
pnpm prisma db push    # only if schema changed
pnpm build
pm2 restart "Rebate Finder"
```

### Scraper update

```bash
bash scripts/scraper/deploy.sh
```

Or manually:
```bash
cd /home/rf/apps/incenva-scraper-service
git pull
go build -o bin/scraper  ./cmd/scraper
go build -o bin/promoter ./cmd/promoter
pm2 restart "Incenva Scraper"
```

---

## 10. Admin users

### Default admin (from seed)

| Email | Password | Role |
|-------|----------|------|
| `admin@incenva.com` | `Admin1234!` | `super_admin` |

**Change this immediately after first login** at `/admin/settings`.

### Create a new admin user

```bash
bash scripts/rebate-finder/create-admin.sh <email> <password> "<Full Name>" <role>

# Examples:
bash scripts/rebate-finder/create-admin.sh ops@example.com StrongPass1! "Ops User" super_admin
bash scripts/rebate-finder/create-admin.sh editor@example.com EditorPass1! "Content Editor" editor
```

Available roles: `super_admin`, `org_admin`, `approver`, `editor`, `viewer`, `agency_collaborator`, `read_only_executive`, `compliance_reviewer`, `analytics_only`, `implementation_partner`

This script is **idempotent** — running it twice with the same email updates the user, not creates a duplicate.

---

## 11. Useful commands

### PM2

```bash
pm2 status                              # all processes
pm2 logs "Rebate Finder"               # tail main app logs
pm2 logs "Incenva Scraper"             # tail scraper logs
pm2 logs "Rebate Finder" --lines 100   # last 100 lines
pm2 restart "Rebate Finder"            # restart main app
pm2 restart "Incenva Scraper"          # restart scraper
pm2 stop "Incenva Scraper"             # stop scraper (keeps PM2 entry)
pm2 delete "Incenva Scraper"           # remove from PM2
```

### PostgreSQL

```bash
# Connect as rf
psql "postgresql://rf:<password>@localhost:5432/rebate_finder"

-- Staging queue status (Go-owned schema)
SELECT stg_promotion_status, COUNT(*) FROM scraper.rebates_staging GROUP BY 1;

-- Live rebates count
SELECT status, COUNT(*) FROM rebates GROUP BY 1;
```

### Nginx

```bash
nginx -t                      # test config syntax
systemctl reload nginx        # apply config changes without downtime
systemctl restart nginx       # full restart
tail -f /var/log/nginx/error.log
```

### Certbot

```bash
certbot renew --dry-run       # test auto-renewal
certbot certificates          # list managed certs + expiry dates
```

### Promote scraped data

```bash
# Run from the main app directory as rf user
cd /home/rf/apps/rebate-finder
pnpm scraper:promote:dry   # preview pending rows
pnpm scraper:promote       # promote to live rebates
```

---

## 12. Troubleshooting

### App not reachable on port 443

1. Nginx running? `systemctl status nginx`
2. App running? `pm2 status`
3. Nginx config valid? `nginx -t`
4. Firewall open? `ufw status`

### PM2 process crashes on startup

```bash
pm2 logs "Rebate Finder" --lines 50
```

Common causes:
- Missing env var: check `DATABASE_URL`, `JWT_SECRET` in `.env`
- Port 3000 already in use: `ss -tlnp | grep 3000`
- Build not done: run `pnpm build` first

### `pnpm: command not found`

```bash
npm install -g pnpm
```

### `go: command not found`

```bash
source /etc/profile.d/golang.sh
# or add to .bashrc:
echo 'export PATH=$PATH:/usr/local/go/bin' >> ~/.bashrc && source ~/.bashrc
```

### PostgreSQL connection refused

```bash
systemctl status postgresql
systemctl start postgresql
```

Check `pg_hba.conf` allows local password auth:
```bash
grep -E "local|127.0.0.1" /etc/postgresql/16/main/pg_hba.conf
# Should include: local all all scram-sha-256
```

### SSL certificate renewal fails

Ensure port 80 is open and Nginx is running (Let's Encrypt uses HTTP-01 challenge):
```bash
ufw allow 80
systemctl status nginx
certbot renew --dry-run
```

### `relation "scraper.rebates_staging" does not exist`

The scraper creates the `scraper` schema and its tables on first startup via GORM AutoMigrate. Verify `DATABASE_URL` and `SCRAPER_DB_SCHEMA` are correct and PostgreSQL is reachable:
```bash
psql "$DATABASE_URL" -c "SELECT 1;"
# Check the schema exists:
psql "$DATABASE_URL" -c "\dn scraper"
```

---

## Appendix: Scraper systemd unit

Alternative to PM2 for the scraper. Use this if you prefer native systemd management.

Create `/etc/systemd/system/incenva-scraper.service` as **root**:

```ini
[Unit]
Description=Incenva Scraper Service
After=network.target postgresql.service
Wants=postgresql.service

[Service]
Type=simple
User=rf
WorkingDirectory=/home/rf/apps/incenva-scraper-service
ExecStart=/home/rf/apps/incenva-scraper-service/bin/scraper
Restart=on-failure
RestartSec=15
EnvironmentFile=/home/rf/apps/incenva-scraper-service/.env

[Install]
WantedBy=multi-user.target
```

Enable and start:
```bash
# run as root
systemctl daemon-reload
systemctl enable --now incenva-scraper
systemctl status incenva-scraper
journalctl -u incenva-scraper -f
```

Restart after update:
```bash
systemctl restart incenva-scraper
```
