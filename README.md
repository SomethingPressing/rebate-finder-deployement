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

**One command creates the Droplet, installs everything, seeds the DB, creates the first admin user, and (optionally) deploys the Fly.io scraper — no SSH or GitHub interaction required.**

```bash
cp secrets.local.example secrets.local   # fill in your tokens — the file is gitignored
bash provision-client.sh
```

`provision-client.sh` loads `secrets.local`, runs a pre-flight check that shows every token and setting it's about to use, asks for confirmation, then hands off to [`scripts/provision.sh`](scripts/provision.sh), which does the work in Steps 0–11. Step 11 (runs only when `FLY_API_TOKEN` is set) creates the Fly.io app for the Go scraper, registers the tenant DB secret, and deploys it.

At the end it prints the server IP, admin login URL, and admin credentials.

Resuming a failed run — skip Droplet creation and reconnect to the existing server:

```bash
DROPLET_IP=167.x.x.x bash provision-client.sh
```

You can also skip the wrapper and drive `scripts/provision.sh` directly with exported environment variables (`source secrets.local && bash scripts/provision.sh`).

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

### What bootstrap does (12 steps, all idempotent)

| Step | What happens |
|------|-------------|
| 1 | Install system packages (git, curl, nginx, ufw, …) |
| 2 | Create `rf` system user |
| 3 | Generate SSH deploy keys (one per GitHub repo) |
| 4 | Write `~/.ssh/config` with host aliases |
| 5 | Print public keys + **pause** for you to add them to GitHub |
| 6 | Verify all three GitHub connections (3 retries) |
| 7 | Clone this deployment repo |
| 8 | Set up Typesense search engine (port 8108) |
| 9 | Set up Next.js app (Node, pnpm, PM2, PostgreSQL, build, start on port 3000) |
| 10 | Go scraper — **skipped**: the scraper runs on Fly.io, not on this server (provision Step 11 deploys it) |
| 11 | Configure nginx reverse proxy (port 80 → localhost:3000) |
| 12 | SSL / Let's Encrypt |

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
# Update the Next.js app (on the server)
bash /home/rf/apps/deployment/scripts/rebate-finder/deploy.sh

# Update the Go scraper (from your workstation — it runs on Fly.io, not the server)
FLY_API_TOKEN=fo1_... bash scripts/scraper/deploy-fly.sh
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
| `provision-client.sh` | **Recommended entry point** — loads `secrets.local`, pre-flight check, then runs `scripts/provision.sh` |
| `scripts/provision.sh` | **Zero-to-live** — creates the Droplet, runs bootstrap, seeds DB, creates admin user, deploys Fly.io scraper (Step 11) |
| `scripts/bootstrap.sh` | **Server setup** — complete fresh server setup in one command (includes Typesense and SSL) |
| `scripts/setup-nginx.sh` | Re-configure nginx (domain change, re-install) — also runs SSL |
| `scripts/setup-ssl.sh` | SSL only — re-issue cert, fix renewal, or add SSL after the fact |
| `scripts/setup-deploy-keys.sh` | Key rotation or if bootstrap was skipped |
| `scripts/verify-deploy-keys.sh` | After adding keys to GitHub |
| `scripts/diagnose.sh` | On the server — PM2 status, DB state, scraper logs, binary version |
| `scripts/rebate-finder/setup-server.sh` | First deploy of Next.js app (called by bootstrap) |
| `scripts/rebate-finder/deploy.sh` | Every code update to the app |
| `scripts/rebate-finder/seed.sh` | Load seed data (sysadmin task) |
| `scripts/rebate-finder/create-admin.sh` | Add/update admin users |
| `scripts/rebate-finder/export-db.sh` | Dump the app database to a `.sql` file |
| `scripts/rebate-finder/fix-portfolio.sh` | One-off backfill of the `rebates.portfolio` column for historical rows |
| `scripts/typesense/setup-server.sh` | Install/configure Typesense (called by bootstrap) |
| `scripts/scraper/setup-fly.sh` | First-time Fly.io app setup for the scraper (called by provision Step 11) |
| `scripts/scraper/deploy-fly.sh` | Every code update to the scraper (deploys to Fly.io) |
| `scripts/scraper/setup-server.sh` | **Not used in production** (scraper is Fly-only) — installs Go + builds binaries on a server; the v0.8 all-in-one test box will reuse it |
| `scripts/scraper/deploy.sh` | On-server scraper update — only relevant where `setup-server.sh` was used |

---

## Documentation

| Doc | Description |
|-----|-------------|
| [docs/deployment.md](docs/deployment.md) | Full deployment guide with manual steps and troubleshooting |
| [docs/ssl-letsencrypt.md](docs/ssl-letsencrypt.md) | SSL / Let's Encrypt setup for dev.incenva.com |
| [docs/github-deploy-keys.md](docs/github-deploy-keys.md) | Deploy key deep-dive — how they work, rotation, troubleshooting |
