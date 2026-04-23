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
    └── local-development.md           ← Local dev setup for both projects
```

---

## Quick start (fresh VPS)

```bash
# 1. Clone this repo onto the server
git clone <this-deployment-repo-url> /home/rf/deployment
cd /home/rf/deployment

# 2. Set up the main Next.js app (installs prerequisites, DB, builds, starts PM2)
sudo APP_REPO_URL=<rebate-finder-repo-url> bash scripts/rebate-finder/setup-server.sh

# 3. Load seed data (separate from code deploys)
bash scripts/rebate-finder/seed.sh

# 4. Set up the Go scraper service
sudo APP_REPO_URL=<scraper-repo-url> bash scripts/scraper/setup-server.sh

# 5. Install Nginx config + SSL
sudo cp nginx/rebate-finder.conf /etc/nginx/sites-available/rebate-finder
sudo ln -sf /etc/nginx/sites-available/rebate-finder /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl reload nginx
sudo certbot --nginx -d rebates.yourclient.com
```

See **[docs/deployment.md](docs/deployment.md)** for the full guide.

---

## Deploying updates

```bash
# Update the main app (after git push to the app repo)
bash scripts/rebate-finder/deploy.sh

# Update the scraper (after git push to the scraper repo)
bash scripts/scraper/deploy.sh
```

---

## Adding an admin user

```bash
bash scripts/rebate-finder/create-admin.sh admin@example.com SecurePass123! "Full Name" super_admin
```

Safe to run multiple times — updates the existing user if the email already exists.

---

## Related repositories

| Repo | Description |
|------|-------------|
| `rebate-finder` | Next.js consumer app (frontend + API) |
| `rebate-finder-scrapers` | Go scraper service (data ingestion) |
| `rebate-finder-deployement` | This repo — deployment scripts + docs |
