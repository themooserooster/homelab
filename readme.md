# My Homelab Setup

## The Intent

The idea here is to have a basic but secure homelab setup that can be accessed in the local home network without traversing the wider internet, but is available through an inexpensive thin proxy when away from home. The away-from-home edge node home should not use or rely on a VPN connection between clients and the edge node.

The homelab itself should use as "vanilla" an open source tech stack as possible. To that end, it assumes Ubuntu LTS as the base host environment, Docker to contain all the applications with as little changes to the Ubuntu host environment as possible. Nginx will be used to host all the applications and Certbot from Let's Encrypt will create and maintain the HTTPS certs.

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

  ```bash
  docker compose run --rm --entrypoint certbot certbot certonly --manual --manual-auth-hook /opt/certbot/acme-dns-auth.py --preferred-challenges dns --manual-public-ip-logging-ok --non-interactive --agree-tos -m you@example.com -d mooserooster.com -d *.mooserooster.com
  ```

1. Verify the cert files exist on the host.

  ```bash
  ls /etc/letsencrypt/live/mooserooster.com/
  ```

1. Start or restart Nginx so it reads the current cert.

  ```bash
  docker compose up -d --force-recreate nginx
  ```

1. Configure unattended renewal from host scheduler (recommended secure option).

  ```bash
  ../cert_creation/renew-and-reload.sh
  ```

1. Optional cron example (runs at 03:17 and 15:17 daily):

  ```bash
  17 3,15 * * * /path/to/homelab/cert_creation/renew-and-reload.sh >> /var/log/certbot-renew.log 2>&1
  ```

1. Confirm renewal checks in logs.

  ```bash
  tail -n 100 /var/log/certbot-renew.log
  ```

Nginx currently expects:

* Certificate: /etc/letsencrypt/live/mooserooster.com/fullchain.pem
* Private key: /etc/letsencrypt/live/mooserooster.com/privkey.pem
