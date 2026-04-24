# Incenva Deployment

This repo contains everything needed to deploy and update the **Incenva Rebate Finder** stack on a fresh Ubuntu 22.04 LTS VPS.

## What's in here

```
rebate-finder-deployement/
├── README.md                          ← You are here
│
├── seeds/
│   └── json/                          ← Seed data (JSON exports, admin-users, brand config)
│
├── scripts/
│   ├── rebate-finder/
│   │   ├── setup-server.sh            ← Full server setup (run once on fresh VPS)
│   │   ├── deploy.sh                  ← Pull + build + restart (run on every code update)
│   │   ├── seed.sh                    ← Load seed data from seeds/json → DB (run separately)
│   │   └── create-admin.sh            ← Add/update an admin user
│   │
│   └── scraper/
│       ├── setup-server.sh            ← Scraper server setup
│       └── deploy.sh                  ← Pull + rebuild + restart scraper
│
├── nginx/
│   └── rebate-finder.conf             ← Nginx virtual host config
│
└── docs/
    ├── deployment.md                  ← Full step-by-step deployment guide
    ├── github-deploy-keys.md          ← SSH deploy key setup (required before first clone)
    └── local-development.md           ← Local dev setup for both projects
```

---

## Repositories

| Repo | SSH URL |
|------|---------|
| `rebate-finder` | `git@github.com:SomethingPressing/rebate-finder.git` |
| `rebate-finder-scrapers` | `git@github.com:SomethingPressing/rebate-finder-scrapers.git` |
| `rebate-finder-deployement` | `git@github.com:SomethingPressing/rebate-finder-deployement.git` |

---

## Quick start (fresh VPS)

### Step 0 — Set up GitHub deploy keys (required first time)

The server needs SSH keys to pull from private GitHub repos without a password.
**→ Follow: [docs/github-deploy-keys.md](docs/github-deploy-keys.md)**

Quick version (run as root):

```bash
# Generate one SSH key per repository
mkdir -p /home/rf/.ssh && chmod 700 /home/rf/.ssh
ssh-keygen -t ed25519 -C "rf@server:rebate-finder"             -f /home/rf/.ssh/id_ed25519_rebate_finder             -N ""
ssh-keygen -t ed25519 -C "rf@server:rebate-finder-scrapers"    -f /home/rf/.ssh/id_ed25519_rebate_finder_scrapers    -N ""
ssh-keygen -t ed25519 -C "rf@server:rebate-finder-deployement" -f /home/rf/.ssh/id_ed25519_rebate_finder_deployement -N ""
chown -R rf:rf /home/rf/.ssh && chmod 600 /home/rf/.ssh/id_ed25519_*

# Write SSH config so git knows which key to use for each repo
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

# Print the three public keys — paste each into GitHub → Repo → Settings → Deploy keys
echo "=== rebate-finder ===" && cat /home/rf/.ssh/id_ed25519_rebate_finder.pub
echo "=== rebate-finder-scrapers ===" && cat /home/rf/.ssh/id_ed25519_rebate_finder_scrapers.pub
echo "=== rebate-finder-deployement ===" && cat /home/rf/.ssh/id_ed25519_rebate_finder_deployement.pub
```

After adding the keys to GitHub, verify each connection:

```bash
sudo -u rf ssh -T github-rebate-finder
sudo -u rf ssh -T github-rebate-finder-scrapers
sudo -u rf ssh -T github-rebate-finder-deployement
# Expected each time: "Hi SomethingPressing/...! You've successfully authenticated..."
```

---

### Step 1 — Clone this deployment repo

```bash
sudo -u rf git clone \
  git@github-rebate-finder-deployement:SomethingPressing/rebate-finder-deployement.git \
  /home/rf/apps/deployment
```

### Step 2 — Set up the main Next.js app

```bash
sudo APP_REPO_URL=git@github-rebate-finder:SomethingPressing/rebate-finder.git \
  bash /home/rf/apps/deployment/scripts/rebate-finder/setup-server.sh
```

### Step 3 — Load seed data

```bash
bash /home/rf/apps/deployment/scripts/rebate-finder/seed.sh
```

### Step 4 — Set up the Go scraper service

```bash
sudo APP_REPO_URL=git@github-rebate-finder-scrapers:SomethingPressing/rebate-finder-scrapers.git \
  bash /home/rf/apps/deployment/scripts/scraper/setup-server.sh
```

### Step 5 — Install Nginx config + SSL

```bash
sudo cp /home/rf/apps/deployment/nginx/rebate-finder.conf /etc/nginx/sites-available/rebate-finder
# Edit the domain name before enabling:
sudo nano /etc/nginx/sites-available/rebate-finder
sudo ln -sf /etc/nginx/sites-available/rebate-finder /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl reload nginx
sudo certbot --nginx -d rebates.yourclient.com
```

See **[docs/deployment.md](docs/deployment.md)** for the complete guide with all options and troubleshooting.

---

## Deploying updates

```bash
# Update the main app (after a git push to the app repo)
bash /home/rf/apps/deployment/scripts/rebate-finder/deploy.sh

# Update the scraper (after a git push to the scraper repo)
bash /home/rf/apps/deployment/scripts/scraper/deploy.sh
```

---

## Adding an admin user

```bash
bash /home/rf/apps/deployment/scripts/rebate-finder/create-admin.sh \
  admin@example.com SecurePass123! "Full Name" super_admin
```

Safe to run multiple times — updates the existing user if the email already exists.

---

## Documentation

| Doc | Description |
|-----|-------------|
| [docs/github-deploy-keys.md](docs/github-deploy-keys.md) | SSH deploy key setup — **start here on a fresh server** |
| [docs/deployment.md](docs/deployment.md) | Full deployment guide (manual + automated) |
| [docs/local-development.md](docs/local-development.md) | Local dev setup for both projects |
