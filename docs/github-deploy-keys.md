# GitHub Deploy Keys — Setup Guide

This guide walks through setting up SSH deploy keys on a fresh Ubuntu server so that the `rf` system user can `git clone` and `git pull` from private GitHub repositories **without a password or personal access token**.

You need one deploy key per repository. This project uses three repos:

| Alias | Repository | Used for |
|-------|-----------|---------|
| `rebate-finder` | `git@github.com:SomethingPressing/rebate-finder.git` | Next.js app |
| `rebate-finder-scrapers` | `git@github.com:SomethingPressing/rebate-finder-scrapers.git` | Go scraper service |
| `rebate-finder-deployement` | `git@github.com:SomethingPressing/rebate-finder-deployement.git` | This deployment repo |

---

## Table of Contents

1. [Prerequisites](#1-prerequisites)
2. [Generate SSH keypairs on the server](#2-generate-ssh-keypairs-on-the-server)
3. [Add public keys to GitHub](#3-add-public-keys-to-github)
4. [Configure SSH on the server](#4-configure-ssh-on-the-server)
5. [Test each connection](#5-test-each-connection)
6. [Clone the repos](#6-clone-the-repos)
7. [How git pull works after setup](#7-how-git-pull-works-after-setup)
8. [Key rotation](#8-key-rotation)
9. [Troubleshooting](#9-troubleshooting)

---

## 1. Prerequisites

- Ubuntu 22.04 LTS server
- Root access (or a user with `sudo`)
- The `rf` system user already created  
  (if not: `adduser --disabled-password --gecos "" rf && usermod -aG sudo rf`)
- GitHub account with admin access to all three repositories
- SSH installed: `which ssh` — it should be at `/usr/bin/ssh`

---

## 2. Generate SSH keypairs on the server

All commands in this section run **as root** and create keys **owned by the `rf` user**.

### 2.1 Create the .ssh directory

```bash
# run as root
mkdir -p /home/rf/.ssh
chmod 700 /home/rf/.ssh
chown rf:rf /home/rf/.ssh
```

### 2.2 Generate one key per repository

Each repository gets its own key. Using `ed25519` (fast, small, secure).

```bash
# run as root

# Key for the main Next.js app
ssh-keygen -t ed25519 \
  -C "rf@server:rebate-finder" \
  -f /home/rf/.ssh/id_ed25519_rebate_finder \
  -N ""

# Key for the Go scraper service
ssh-keygen -t ed25519 \
  -C "rf@server:rebate-finder-scrapers" \
  -f /home/rf/.ssh/id_ed25519_rebate_finder_scrapers \
  -N ""

# Key for this deployment repo
ssh-keygen -t ed25519 \
  -C "rf@server:rebate-finder-deployement" \
  -f /home/rf/.ssh/id_ed25519_rebate_finder_deployement \
  -N ""

# Fix ownership so rf user can read them
chown -R rf:rf /home/rf/.ssh
chmod 600 /home/rf/.ssh/id_ed25519_*
chmod 644 /home/rf/.ssh/id_ed25519_*.pub
```

### 2.3 Print the public keys

You'll need these in the next step. Print each one:

```bash
echo "=== rebate-finder ==="
cat /home/rf/.ssh/id_ed25519_rebate_finder.pub

echo ""
echo "=== rebate-finder-scrapers ==="
cat /home/rf/.ssh/id_ed25519_rebate_finder_scrapers.pub

echo ""
echo "=== rebate-finder-deployement ==="
cat /home/rf/.ssh/id_ed25519_rebate_finder_deployement.pub
```

Each key looks like:
```
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA... rf@server:rebate-finder
```

Copy each one — you'll paste them into GitHub in the next step.

---

## 3. Add public keys to GitHub

Repeat these steps for **each of the three repositories**.

### Steps (do this on github.com)

1. Open the repository on GitHub  
   e.g. `https://github.com/SomethingPressing/rebate-finder`

2. Click **Settings** (the repo settings tab, not your account settings)

3. In the left sidebar click **Deploy keys**

4. Click **Add deploy key**

5. Fill in:
   - **Title:** `rf@<your-server-hostname>` (e.g. `rf@vps-01`)
   - **Key:** paste the public key for this repo
   - **Allow write access:** ❌ leave unchecked  
     Deploy keys only need read access for `git clone` / `git pull`

6. Click **Add key**

### Which key goes to which repo

| Repository | Public key file |
|-----------|----------------|
| `rebate-finder` | `/home/rf/.ssh/id_ed25519_rebate_finder.pub` |
| `rebate-finder-scrapers` | `/home/rf/.ssh/id_ed25519_rebate_finder_scrapers.pub` |
| `rebate-finder-deployement` | `/home/rf/.ssh/id_ed25519_rebate_finder_deployement.pub` |

> GitHub does not allow the same key to be added to more than one repository. That's why we generate separate keys.

---

## 4. Configure SSH on the server

SSH needs to know which private key to use for which GitHub repository. We do this with a per-repo **Host alias** in `~/.ssh/config`.

### 4.1 Write the SSH config

Run as **root**:

```bash
cat > /home/rf/.ssh/config << 'EOF'
# ── Global GitHub settings ────────────────────────────────────────────────────
Host github.com
    HostName github.com
    User git
    StrictHostKeyChecking accept-new

# ── Per-repo host aliases ─────────────────────────────────────────────────────
# These aliases are used in the git clone/pull URLs instead of "github.com".
# The alias is arbitrary — it just needs to match what you use in git remote set-url.

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

chown rf:rf /home/rf/.ssh/config
chmod 600 /home/rf/.ssh/config
```

**What this does:** When git uses `github-rebate-finder` as the hostname in a URL, SSH substitutes `github.com` but authenticates with the specific key for that repo. This is how one server can have separate read-only keys for multiple repos.

---

## 5. Test each connection

Run as the **`rf` user** (`sudo -u rf -i` to switch):

```bash
sudo -u rf -i
```

Then test all three:

```bash
ssh -T github-rebate-finder
# Expected: Hi SomethingPressing/rebate-finder! You've successfully authenticated...

ssh -T github-rebate-finder-scrapers
# Expected: Hi SomethingPressing/rebate-finder-scrapers! You've successfully authenticated...

ssh -T github-rebate-finder-deployement
# Expected: Hi SomethingPressing/rebate-finder-deployement! You've successfully authenticated...
```

> If you see `Hi SomethingPressing!` (without the repo name), the key resolved to your personal GitHub account — it still works for any repo you have access to, which is fine.

> If you see `Permission denied (publickey)`, jump to [Troubleshooting](#9-troubleshooting).

---

## 6. Clone the repos

Now use the SSH alias hostnames (not `github.com`) in your clone URLs.

Run as the **`rf` user**:

```bash
sudo -u rf -i

mkdir -p /home/rf/apps
cd /home/rf/apps

# 1. Deployment repo (scripts and seed data)
git clone git@github-rebate-finder-deployement:SomethingPressing/rebate-finder-deployement.git deployment

# 2. Next.js app
git clone git@github-rebate-finder:SomethingPressing/rebate-finder.git rebate-finder

# 3. Go scraper service
git clone git@github-rebate-finder-scrapers:SomethingPressing/rebate-finder-scrapers.git incenva-scraper-service
```

Verify:
```bash
ls /home/rf/apps/
# deployment  rebate-finder  incenva-scraper-service
```

---

## 7. How git pull works after setup

Because each repo was cloned via the aliased SSH URL, `git pull` automatically uses the correct key:

```bash
# As rf user — no password, no token needed
cd /home/rf/apps/rebate-finder
git pull        # uses id_ed25519_rebate_finder automatically

cd /home/rf/apps/incenva-scraper-service
git pull        # uses id_ed25519_rebate_finder_scrapers automatically
```

The deploy scripts (`scripts/rebate-finder/deploy.sh`, `scripts/scraper/deploy.sh`) already run `git pull` — they work out of the box once the SSH config is in place.

### Setting the remote on an existing clone

If a repo was cloned via HTTPS and you want to switch it to use the SSH alias:

```bash
cd /home/rf/apps/rebate-finder
git remote set-url origin git@github-rebate-finder:SomethingPressing/rebate-finder.git
git remote -v  # verify
```

---

## 8. Key rotation

When you need to rotate keys (e.g., server compromise, key expiry policy):

### Generate a new key

```bash
# run as root — example for rebate-finder
ssh-keygen -t ed25519 \
  -C "rf@server:rebate-finder-$(date +%Y%m%d)" \
  -f /home/rf/.ssh/id_ed25519_rebate_finder_new \
  -N ""
chown rf:rf /home/rf/.ssh/id_ed25519_rebate_finder_new*
chmod 600 /home/rf/.ssh/id_ed25519_rebate_finder_new
```

### Add the new key to GitHub first

Go to the repo's Deploy keys page and add the new `.pub` content **before** removing the old key.

### Swap the key file

```bash
# run as root
mv /home/rf/.ssh/id_ed25519_rebate_finder /home/rf/.ssh/id_ed25519_rebate_finder_old
mv /home/rf/.ssh/id_ed25519_rebate_finder_new /home/rf/.ssh/id_ed25519_rebate_finder
chown rf:rf /home/rf/.ssh/id_ed25519_rebate_finder
chmod 600 /home/rf/.ssh/id_ed25519_rebate_finder
```

The `~/.ssh/config` already points to the filename — no config change needed.

### Test, then remove the old key from GitHub

```bash
sudo -u rf ssh -T github-rebate-finder
# Confirm: "successfully authenticated"
```

Then delete the old key from the GitHub Deploy keys page.

### Clean up

```bash
rm /home/rf/.ssh/id_ed25519_rebate_finder_old
```

---

## 9. Troubleshooting

### `Permission denied (publickey)`

**Check 1 — Is the public key added to GitHub?**  
```bash
cat /home/rf/.ssh/id_ed25519_rebate_finder.pub
```
Compare with what's shown in GitHub → Repo Settings → Deploy keys. They must match exactly.

**Check 2 — Are file permissions correct?**
```bash
ls -la /home/rf/.ssh/
# id_ed25519_*       must be -rw------- (600)
# id_ed25519_*.pub   must be -rw-r--r-- (644)
# config             must be -rw------- (600)
# .ssh dir itself    must be drwx------ (700)
```

Fix with:
```bash
chmod 700 /home/rf/.ssh
chmod 600 /home/rf/.ssh/id_ed25519_*
chmod 644 /home/rf/.ssh/id_ed25519_*.pub
chmod 600 /home/rf/.ssh/config
```

**Check 3 — Are you testing as the right user?**  
Must be the `rf` user, not root:
```bash
sudo -u rf ssh -T github-rebate-finder
```

**Check 4 — Verbose SSH output**  
```bash
sudo -u rf ssh -vT github-rebate-finder 2>&1 | grep -E "(identity|Offering|Authenticated|denied)"
```
Look for:
- `Offering public key: /home/rf/.ssh/id_ed25519_rebate_finder` — key is being offered ✓
- `Server accepts key` — GitHub accepted it ✓
- `Permission denied` with no key offered — SSH config or path is wrong

---

### `Host key verification failed`

GitHub's host key changed or was never accepted. Fix:

```bash
sudo -u rf ssh-keyscan github.com >> /home/rf/.ssh/known_hosts
chown rf:rf /home/rf/.ssh/known_hosts
```

The `StrictHostKeyChecking accept-new` line in the SSH config handles this automatically for new hosts, but if a stale entry exists:

```bash
sudo -u rf ssh-keygen -R github.com
sudo -u rf ssh-keyscan github.com >> /home/rf/.ssh/known_hosts
```

---

### `git pull` still asks for a username/password

The repo's remote is using HTTPS, not SSH:

```bash
cd /home/rf/apps/rebate-finder
git remote -v
# origin  https://github.com/SomethingPressing/rebate-finder.git  ← wrong

git remote set-url origin git@github-rebate-finder:SomethingPressing/rebate-finder.git
git remote -v
# origin  git@github-rebate-finder:SomethingPressing/rebate-finder.git  ← correct
```

---

### SSH config not being picked up

Check that the config file is readable by the `rf` user and has correct syntax:

```bash
sudo -u rf cat /home/rf/.ssh/config
sudo -u rf ssh -G github-rebate-finder | grep identityfile
# Should print: identityfile /home/rf/.ssh/id_ed25519_rebate_finder
```

---

### Key file is owned by root

```bash
ls -la /home/rf/.ssh/id_ed25519_*
# If owner is root:root, fix with:
chown rf:rf /home/rf/.ssh/id_ed25519_*
```

---

## Summary: Full sequence for a fresh server

```bash
# 1. As root: create rf user (skip if exists)
adduser --disabled-password --gecos "" rf

# 2. As root: generate keys
mkdir -p /home/rf/.ssh && chmod 700 /home/rf/.ssh
ssh-keygen -t ed25519 -C "rf@server:rebate-finder"             -f /home/rf/.ssh/id_ed25519_rebate_finder             -N ""
ssh-keygen -t ed25519 -C "rf@server:rebate-finder-scrapers"    -f /home/rf/.ssh/id_ed25519_rebate_finder_scrapers    -N ""
ssh-keygen -t ed25519 -C "rf@server:rebate-finder-deployement" -f /home/rf/.ssh/id_ed25519_rebate_finder_deployement -N ""
chown -R rf:rf /home/rf/.ssh && chmod 600 /home/rf/.ssh/id_ed25519_*

# 3. As root: write SSH config
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

# 4. Print public keys — paste each into GitHub Deploy keys
cat /home/rf/.ssh/id_ed25519_rebate_finder.pub
cat /home/rf/.ssh/id_ed25519_rebate_finder_scrapers.pub
cat /home/rf/.ssh/id_ed25519_rebate_finder_deployement.pub

# ↑ Add each to its repo: GitHub → Repo Settings → Deploy keys → Add deploy key

# 5. Test (as rf user)
sudo -u rf ssh -T github-rebate-finder
sudo -u rf ssh -T github-rebate-finder-scrapers
sudo -u rf ssh -T github-rebate-finder-deployement

# 6. Clone (as rf user)
sudo -u rf bash -c "
  mkdir -p /home/rf/apps
  git clone git@github-rebate-finder-deployement:SomethingPressing/rebate-finder-deployement.git /home/rf/apps/deployment
  git clone git@github-rebate-finder:SomethingPressing/rebate-finder.git /home/rf/apps/rebate-finder
  git clone git@github-rebate-finder-scrapers:SomethingPressing/rebate-finder-scrapers.git /home/rf/apps/incenva-scraper-service
"

# 7. Continue with the rest of setup
bash /home/rf/apps/deployment/scripts/rebate-finder/setup-server.sh
```
