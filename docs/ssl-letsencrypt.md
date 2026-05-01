# SSL / Let's Encrypt — dev.incenva.com

Step-by-step guide to getting a free TLS certificate from Let's Encrypt for the Incenva Rebate Finder running on **dev.incenva.com**.

---

## Prerequisites

Before running any command below:

| Requirement | How to verify |
|-------------|---------------|
| Ubuntu 22.04 VPS | `lsb_release -a` |
| Nginx installed and running | `systemctl status nginx` |
| Ports 80 **and** 443 open in firewall | `ufw status` |
| DNS A record `dev.incenva.com` → server's public IP | `dig +short dev.incenva.com` |
| Next.js app running on `localhost:3000` | `pm2 status` |

> **DNS must resolve before running Certbot.** Let's Encrypt validates the domain over the public internet using an HTTP challenge.  
> Quick check: `curl -s http://dev.incenva.com` should reach your server (even a 404 is fine — the TCP connection must succeed).

---

## 1. Install Certbot

```bash
# run as root
apt-get update
apt-get install -y certbot python3-certbot-nginx
certbot --version   # certbot 2.x.x
```

---

## 2. Set the domain in the Nginx config

The existing config at `/etc/nginx/sites-available/rebate-finder` ships with `server_name _;` (catch-all). Update it to the real domain first so Certbot can find and patch it.

```bash
# run as root
nano /etc/nginx/sites-available/rebate-finder
```

Change this line:
```nginx
server_name _;
```
to:
```nginx
server_name dev.incenva.com;
```

Save, then reload Nginx:
```bash
nginx -t && systemctl reload nginx
```

---

## 3. Obtain the certificate

```bash
# run as root
certbot --nginx -d dev.incenva.com
```

When prompted:
- **Email address** — enter a real address (used for expiry warnings)
- **Terms of Service** → `A` to agree
- **Share email with EFF** → your choice

Certbot performs an HTTP-01 challenge, issues the certificate, and automatically patches `/etc/nginx/sites-available/rebate-finder`.

**Expected success output:**
```
Successfully received certificate.
Certificate is saved at: /etc/letsencrypt/live/dev.incenva.com/fullchain.pem
Key is saved at:         /etc/letsencrypt/live/dev.incenva.com/privkey.pem
This certificate expires on YYYY-MM-DD.

Deploying certificate to VirtualHost /etc/nginx/sites-enabled/rebate-finder
Redirecting all traffic on port 80 to ssl in /etc/nginx/sites-enabled/rebate-finder

Congratulations! You have successfully enabled HTTPS on https://dev.incenva.com
```

---

## 4. What your Nginx config looks like after Certbot

Certbot rewrites `/etc/nginx/sites-available/rebate-finder` to something like:

```nginx
server {
    listen 80;
    listen [::]:80;
    server_name dev.incenva.com;
    return 301 https://$host$request_uri;   # added by Certbot
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name dev.incenva.com;

    # Managed by Certbot
    ssl_certificate     /etc/letsencrypt/live/dev.incenva.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/dev.incenva.com/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;

    # Security headers
    add_header X-Frame-Options        "SAMEORIGIN"                      always;
    add_header X-Content-Type-Options "nosniff"                         always;
    add_header Referrer-Policy        "strict-origin-when-cross-origin" always;
    add_header X-XSS-Protection       "1; mode=block"                   always;

    client_max_body_size 50M;

    location / {
        proxy_pass         http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_set_header   Upgrade           $http_upgrade;
        proxy_set_header   Connection        'upgrade';
        proxy_set_header   Host              $host;
        proxy_set_header   X-Real-IP         $remote_addr;
        proxy_set_header   X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto $scheme;
        proxy_cache_bypass $http_upgrade;
        proxy_read_timeout 60s;
    }
}
```

After any manual edits always reload:
```bash
nginx -t && systemctl reload nginx
```

---

## 5. Verify

```bash
# List certificates and expiry date
certbot certificates

# Test HTTPS
curl -I https://dev.incenva.com
# HTTP/2 200  (or a redirect from the app itself)

# Check certificate details
echo | openssl s_client -connect dev.incenva.com:443 -servername dev.incenva.com 2>/dev/null \
  | openssl x509 -noout -subject -dates
```

---

## 6. Update the app's base URL

With HTTPS live, make sure the `.env` in the Next.js app reflects the correct origin:

```bash
nano /home/rf/apps/rebate-finder/.env
```

Set:
```env
NEXT_BASE_URL=https://dev.incenva.com
```

Rebuild and restart:
```bash
bash /home/rf/apps/deployment/scripts/rebate-finder/deploy.sh
```

---

## 7. Auto-renewal

Certbot installs a **systemd timer** that renews certificates automatically ~30 days before expiry (Let's Encrypt certs last 90 days).

Confirm the timer is active:
```bash
systemctl status certbot.timer
# Active: active (waiting)
```

Test a dry-run:
```bash
certbot renew --dry-run
# Congratulations, all simulated renewals succeeded
```

> Port 80 must remain open and Nginx must be running at all times — the renewal challenge uses HTTP on port 80.

---

## 8. Manual renewal (if needed)

```bash
# run as root
certbot renew
systemctl reload nginx
```

---

## Troubleshooting

### `DNS problem: NXDOMAIN looking up A for dev.incenva.com`

The A record doesn't exist or hasn't propagated yet.

1. Create the A record in your DNS provider: `dev.incenva.com` → server public IP
2. Wait a few minutes, then verify: `dig +short dev.incenva.com`
3. Re-run Certbot once DNS resolves

### `Error: Could not bind to port 80`

You may be running `--standalone` by mistake. Always use the `--nginx` plugin — it doesn't need to unbind Nginx:
```bash
certbot --nginx -d dev.incenva.com
```

### `403 / connection refused` during HTTP challenge

Certbot couldn't reach `http://dev.incenva.com/.well-known/acme-challenge/…`:
```bash
ufw status | grep 80          # port 80 must be open
systemctl status nginx         # Nginx must be running
nginx -t                       # config must be valid
```

### Certificate expired / failed to auto-renew

```bash
certbot renew --force-renewal
systemctl reload nginx

# Re-enable the renewal timer if it was somehow disabled
systemctl enable --now certbot.timer
```

---

## Quick-reference cheat sheet

```bash
# One-time setup
apt-get install -y certbot python3-certbot-nginx
# Set server_name dev.incenva.com in /etc/nginx/sites-available/rebate-finder
nginx -t && systemctl reload nginx
certbot --nginx -d dev.incenva.com

# Verify
certbot certificates
curl -I https://dev.incenva.com

# Test auto-renewal
certbot renew --dry-run
systemctl status certbot.timer

# Force renew now
certbot renew --force-renewal && systemctl reload nginx

# Check expiry
echo | openssl s_client -connect dev.incenva.com:443 -servername dev.incenva.com 2>/dev/null \
  | openssl x509 -noout -dates
```
