# Incenva Deployment

Scripts and configuration to deploy the **Incenva Rebate Finder** stack on a fresh Ubuntu 22.04 LTS VPS.

---

## Repositories

| App | SSH URL |
|-----|---------|
| Deployment (this repo) | `git@github.com:SomethingPressing/rebate-finder-deployement.git` |
| Next.js app | `git@github.com:SomethingPressing/rebate-finder.git` |
| Go scraper service | `git@github.com:SomethingPressing/rebate-finder-scrapers.git` |

---

## Fully automated provisioning (recommended)

**One command creates the Droplet, installs everything, seeds the DB, and creates the first admin user — no SSH or GitHub interaction required.**

```bash
export DO_API_TOKEN=dop_v1_...      # DigitalOcean API token
export GITHUB_PAT=ghp_...           # GitHub PAT (repo scope) — auto-registers deploy keys
export OPENAI_API_KEY=sk-...        # OpenAI key
export APP_DOMAIN=client.incenva.com
export DO_SSH_KEY_IDS=12345678      # your personal DO SSH key ID (optional, for direct access)

bash scripts/provision.sh
```

At the end it prints the server IP, admin login URL, and admin credentials. See [`scripts/provision.sh`](scripts/provision.sh) for the full list of options.

---

## Manual setup — one command on the server

Run this on an **existing fresh Ubuntu 22.04 server** as root. With `GITHUB_PAT` set, deploy keys register automatically:

```bash
export GITHUB_PAT=ghp_...
APP_DOMAIN=dev.incenva.com \
  curl -fsSL https://raw.githubusercontent.com/SomethingPressing/rebate-finder-deployement/main/scripts/bootstrap.sh \
  | sudo bash
```

Without `GITHUB_PAT`, the script pauses once to let you add SSH deploy keys to GitHub manually.

> **No curl yet?** Run `apt-get update && apt-get install -y curl` first.

### What bootstrap does (10 steps, all idempotent)

| Step | What happens |
|------|-------------|
| 1 | Install system packages (git, curl, nginx, ufw, …) |
| 2 | Create `rf` system user |
| 3 | Generate SSH deploy keys (one per GitHub repo) |
| 4 | Write `~/.ssh/config` with host aliases |
| 5 | Print public keys + **pause** for you to add them to GitHub |
| 6 | Verify all three GitHub connections (3 retries) |
| 7 | Clone this deployment repo |
| 8 | Set up Next.js app (Node, pnpm, PM2, PostgreSQL, build, start on port 3000) |
| 9 | Set up Go scraper service (Go, build binaries) |
| 10 | Configure nginx reverse proxy (port 80 → localhost:3000) |

Safe to re-run — every step checks if work is already done and skips it.

---

## After bootstrap

### 1 — Fill in remaining `.env` values

```bash
nano /home/rf/apps/rebate-finder/.env
```

| Variable | Required | Description |
|----------|----------|-------------|
| `OPENAI_API_KEY` | **Yes** | AI content rewrite, translation, Incenva IQ chat |
| `BREVO_API_KEY` | No | Transactional email (notification emails) |
| `BREVO_SENDER_EMAIL` | No | From address for notification emails |
| `NEXT_PUBLIC_GTM_ID` | No | Google Tag Manager ID (e.g. `GTM-XXXXXXX`) |
| `TYPESENSE_API_KEY` | No | Fast keyword search — falls back to Postgres if absent |
| `PROMOTER_SYNC_SECRET` | No | Shared secret used by scraper to trigger Typesense re-index |

Auto-set by bootstrap: `DATABASE_URL`, `JWT_SECRET`, `PORT`, `NEXT_BASE_URL`.

### 2 — Rebuild after editing `.env`

```bash
bash /home/rf/apps/deployment/scripts/rebate-finder/deploy.sh
```

### 3 — Load seed data (sysadmin, run once)

```bash
# Default seed data (from this deployment repo)
bash /home/rf/apps/deployment/scripts/rebate-finder/seed.sh

# Or point to a custom seed folder
bash /home/rf/apps/deployment/scripts/rebate-finder/seed.sh /path/to/seeds/json
```

### 4 — Add an admin user

```bash
bash /home/rf/apps/deployment/scripts/rebate-finder/create-admin.sh \
  email@example.com SecurePass123! "Full Name" super_admin
```

---

## Deploying updates

After pushing code changes to GitHub:

```bash
# Update the Next.js app
bash /home/rf/apps/deployment/scripts/rebate-finder/deploy.sh

# Update the Go scraper
bash /home/rf/apps/deployment/scripts/scraper/deploy.sh
```

---

## Other useful scripts

```bash
# Re-run nginx setup (e.g. to change domain)
sudo APP_DOMAIN=newdomain.com bash /home/rf/apps/deployment/scripts/setup-nginx.sh

# Re-run deploy key generation (e.g. after key rotation)
sudo bash /home/rf/apps/deployment/scripts/setup-deploy-keys.sh

# Verify GitHub SSH connections
bash /home/rf/apps/deployment/scripts/verify-deploy-keys.sh
```

---

## All scripts

| Script | When to run |
|--------|-------------|
| `scripts/provision.sh` | **Zero-to-live** — creates the Droplet, runs bootstrap, seeds DB, creates admin user |
| `scripts/bootstrap.sh` | **Server setup** — complete fresh server setup in one command (includes SSL) |
| `scripts/setup-nginx.sh` | Re-configure nginx (domain change, re-install) — also runs SSL |
| `scripts/setup-ssl.sh` | SSL only — re-issue cert, fix renewal, or add SSL after the fact |
| `scripts/setup-deploy-keys.sh` | Key rotation or if bootstrap was skipped |
| `scripts/verify-deploy-keys.sh` | After adding keys to GitHub |
| `scripts/rebate-finder/setup-server.sh` | First deploy of Next.js app (called by bootstrap) |
| `scripts/rebate-finder/deploy.sh` | Every code update to the app |
| `scripts/rebate-finder/seed.sh` | Load seed data (sysadmin task) |
| `scripts/rebate-finder/create-admin.sh` | Add/update admin users |
| `scripts/scraper/setup-server.sh` | First deploy of Go scraper (called by bootstrap) |
| `scripts/scraper/deploy.sh` | Every code update to the scraper |

---

## Documentation

| Doc | Description |
|-----|-------------|
| [docs/deployment.md](docs/deployment.md) | Full deployment guide with manual steps and troubleshooting |
| [docs/ssl-letsencrypt.md](docs/ssl-letsencrypt.md) | SSL / Let's Encrypt setup for dev.incenva.com |
| [docs/github-deploy-keys.md](docs/github-deploy-keys.md) | Deploy key deep-dive — how they work, rotation, troubleshooting |
