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

## Full server setup — one command

Run this on a **fresh Ubuntu 22.04 server** as root, replacing the domain with your real one:

```bash
APP_DOMAIN=dev.incenva.com curl -fsSL https://raw.githubusercontent.com/SomethingPressing/rebate-finder-deployement/main/scripts/bootstrap.sh | sudo bash
```

> **No curl yet?** Run `apt-get update && apt-get install -y curl` first.

The script will pause once to let you add SSH deploy keys to GitHub, then complete the rest automatically.

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
| 9 | Set up Go scraper service (Go, build, PM2) |
| 10 | Configure nginx reverse proxy (port 80 → localhost:3000) |

Safe to re-run — every step checks if work is already done and skips it.

---

## After bootstrap

### 1 — Fill in remaining `.env` values

```bash
nano /home/rf/apps/rebate-finder/.env
```

| Variable | Description |
|----------|-------------|
| `NEXT_PUBLIC_SUPABASE_URL` | Supabase project URL |
| `NEXT_PUBLIC_SUPABASE_ANON_KEY` | Supabase anon key |
| `SUPABASE_SERVICE_KEY` | Supabase service role key |
| `OPENAI_API_KEY` | For AI content generation |

Auto-set by bootstrap: `DATABASE_URL`, `JWT_SECRET`, `PORT`, `NEXT_BASE_URL`.

```bash
nano /home/rf/apps/incenva-scraper-service/.env
```

| Variable | Description |
|----------|-------------|
| `REWIRING_AMERICA_API_KEY` | Rewiring America calculator API key |

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
| `scripts/bootstrap.sh` | **First** — complete fresh server setup in one command |
| `scripts/setup-nginx.sh` | Re-configure nginx (domain change, re-install) |
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
| [docs/github-deploy-keys.md](docs/github-deploy-keys.md) | Deploy key deep-dive — how they work, rotation, troubleshooting |
