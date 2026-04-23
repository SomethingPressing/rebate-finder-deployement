# Local Development

Setup guide for running both the **Incenva Rebate Finder** (Next.js) and the **Incenva Scraper Service** (Go) locally.

---

## Prerequisites

| Tool | Version | Install |
|------|---------|---------|
| Node.js | 20 LTS | https://nodejs.org or `brew install node@20` |
| pnpm | 9.x | `npm install -g pnpm` |
| Go | 1.24+ | https://go.dev/dl/ or `brew install go` |
| PostgreSQL | 14+ | Local install or Supabase cloud |
| Git | 2.x | https://git-scm.com |

---

## Main app (Next.js)

### 1. Clone and install

```bash
git clone <rebate-finder-repo-url>
cd rebate-finder
pnpm install
```

### 2. Configure environment

```bash
cp .env.example .env
```

Required variables for local dev:

| Variable | How to get it |
|----------|--------------|
| `DATABASE_URL` | Local psql DSN or Supabase connection string |
| `JWT_SECRET` | `node -e "console.log(require('crypto').randomBytes(64).toString('hex'))"` |
| `NEXT_PUBLIC_SUPABASE_URL` | Supabase → Project Settings → API → Project URL |
| `NEXT_PUBLIC_SUPABASE_ANON_KEY` | Supabase → Project Settings → API → anon key |
| `NEXT_PUBLIC_SUPABASE_PROJECT_ID` | Subdomain from your Supabase URL |
| `SUPABASE_SERVICE_KEY` | Supabase → Project Settings → API → service_role key |

Everything else is optional for local dev.

### 3. Set up the database

**Option A — Local PostgreSQL:**
```bash
psql -U postgres -c "CREATE DATABASE rebate_finder;"
psql -U postgres -c "CREATE USER rebate_user WITH PASSWORD 'localpass';"
psql -U postgres -c "GRANT ALL PRIVILEGES ON DATABASE rebate_finder TO rebate_user;"
# Set DATABASE_URL=postgresql://rebate_user:localpass@localhost:5432/rebate_finder
```

**Option B — Supabase (cloud):**
Paste the connection string from Supabase → Project Settings → Database into `DATABASE_URL`.

### 4. Push schema and seed

```bash
pnpm prisma db push       # Create/update tables
pnpm prisma generate      # Regenerate Prisma client
pnpm db:seed              # Load sample data + default admin user
```

### 5. Run the dev server

```bash
pnpm dev
```

Open **http://localhost:3000**. Admin panel is at `/admin/login`.

**Default admin credentials (from seed):**
- Email: `admin@incenva.com`
- Password: `Admin1234!`

### 6. Run tests

```bash
pnpm test              # Unit tests (Vitest)
pnpm test:watch        # Watch mode
pnpm test:coverage     # Coverage report (70% threshold)
pnpm test:integration  # Integration tests
```

### Available commands

| Command | Description |
|---------|-------------|
| `pnpm dev` | Dev server with HMR |
| `pnpm build` | Production build |
| `pnpm start` | Start production server |
| `pnpm lint` | ESLint |
| `pnpm typecheck` | TypeScript check |
| `pnpm prisma db push` | Apply schema to DB |
| `pnpm prisma generate` | Regenerate Prisma client |
| `pnpm prisma studio` | Visual DB browser at :5555 |
| `pnpm db:seed` | Seed data |
| `pnpm scraper:promote:dry` | Preview staged rows |
| `pnpm scraper:promote` | Promote staged rows → live |

---

## Scraper service (Go)

### 1. Clone and install

```bash
git clone <rebate-finder-scrapers-repo-url>
cd rebate-finder-scrapers
go mod download
```

### 2. Configure environment

```bash
cp .env.example .env
```

Required:
```env
DATABASE_URL=postgresql://rebate_user:localpass@localhost:5432/rebate_finder
REWIRING_AMERICA_API_KEY=<your-key>   # get free key at rewiringamerica.org/api
```

### 3. Run scrapers

```bash
# All sources, run once
RUN_ONCE=true LOG_FORMAT=console go run ./cmd/scraper

# Single source
SOURCE=dsireusa RUN_ONCE=true LOG_FORMAT=console go run ./cmd/scraper

# Scheduled mode (runs every 6 hours)
go run ./cmd/scraper
```

### 4. PDF scraper (Consumers Energy)

```bash
LOG_FORMAT=console go run ./cmd/pdf-scraper \
  --catalog  /path/to/Consumers_Energy_Incentive_Catalog.pdf \
  --application /path/to/Incentive-Application.pdf
```

### 5. Build binaries

```bash
go build -o bin/scraper ./cmd/scraper
go build -o bin/pdf-scraper ./cmd/pdf-scraper
```

### 6. Promote staged data (from the main app)

After a scraper run, rows land in `rebates_staging`. Promote them to live rebates:

```bash
cd ../rebate-finder
pnpm scraper:promote:dry   # preview
pnpm scraper:promote       # write to live rebates table
```

---

## Troubleshooting

### `DATABASE_URL` connection refused
```bash
sudo systemctl start postgresql     # Linux
brew services start postgresql@16   # macOS
```

### `pnpm: command not found`
```bash
npm install -g pnpm
```

### `go: command not found`
```bash
export PATH=$PATH:/usr/local/go/bin
# or: source /etc/profile.d/golang.sh
```

### `prisma db push` permission error
```sql
GRANT ALL PRIVILEGES ON DATABASE rebate_finder TO rebate_user;
```

### Prisma client out of sync after schema change
```bash
pnpm prisma db push
pnpm prisma generate
```

### Rewiring America returns 0 results
Set `REWIRING_AMERICA_API_KEY` in `.env` — the API returns 401 with a missing/invalid key.

### PDF scraper: "catalog PDF not found"
Pass explicit paths via CLI flags:
```bash
go run ./cmd/pdf-scraper \
  --catalog     /absolute/path/to/catalog.pdf \
  --application /absolute/path/to/application.pdf
```
