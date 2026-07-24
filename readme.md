# My Homelab Setup

## Architecture

This homelab setup has two main parts:

* The local server where all the fun happens
* The VPS to safely (I hope) expose it to the internet

...And a Wireguard VPN tunnel to link the two.

## Apps

* Jellyfin
* Immich (Someday)

## TLS Cert Workflow (Docker)

Certbot is configured for one-shot runs from [local/compose.yml](local/compose.yml), and unattended renewal is driven by a host scheduler (cron or systemd timer). This avoids granting the Certbot container access to Docker socket.

Run these commands from [local](local):

1. Issue the initial cert (one-time) with DNS challenge.

	docker compose run --rm --entrypoint certbot certbot certonly --manual --manual-auth-hook /opt/certbot/acme-dns-auth.py --preferred-challenges dns --manual-public-ip-logging-ok --non-interactive --agree-tos -m you@example.com -d mooserooster.com -d *.mooserooster.com

2. Verify the cert files exist on the host.

	ls /etc/letsencrypt/live/mooserooster.com/

3. Start or restart Nginx so it reads the current cert.

	docker compose up -d --force-recreate nginx

4. Configure unattended renewal from host scheduler (recommended secure option).

	../cert_creation/renew-and-reload.sh

5. Optional cron example (runs at 03:17 and 15:17 daily):

	17 3,15 * * * /path/to/homelab/cert_creation/renew-and-reload.sh >> /var/log/certbot-renew.log 2>&1

6. Confirm renewal checks in logs.

	tail -n 100 /var/log/certbot-renew.log

Nginx currently expects:

* Certificate: /etc/letsencrypt/live/mooserooster.com/fullchain.pem
* Private key: /etc/letsencrypt/live/mooserooster.com/privkey.pem
