# My Homelab Setup

## The Intent

The idea here is to have a basic but secure homelab setup that can be accessed in the local home network without traversing the wider internet, but is available through an inexpensive thin proxy when away from home.

The homelab itself should use as "vanilla" an open source tech stack as possible. To that end, it assumes Ubuntu LTS as the base host environment, Docker to contain all the applications with as little changes to the Ubuntu host environment as possible. Nginx will be used to host all the applications and Certbot from Let's Encrypt will create and maintain the HTTPS certs.

* Two nodes:
  1. The "home" node located on premises in the house, which hosts all the applications in docker containers, creates and updates the HTTPS/SSL certs in a host level cron job, and serves local DNS on the home network so all home network traffic going to hosted applications doesn't have to leave the home network and consume edge node bandwidth. All hosted applications will be at `https://<app>.$DOMAIN` (see `DOMAIN` in `local/.env`).
  2. The "edge" node, a lightweight VPS in a major cloud provider (DigitalOcean) that forwards network traffic to the "home" node for it to handle. The edge node should not use or rely on a VPN connection between clients and the edge node. The edge node leverages all the security features of the cloud provider.
* A Wireguard VPN connecting the two nodes. The edge node should forward all legitimate traffic to the home node via the Wireguard VPN connection.
  * I don't have an opinion on how the two nodes should establish the wireguard.

## Architecture

This homelab setup has two main parts:

* The local server where all the fun happens
* The VPS to safely (I hope) expose it to the internet

...And a Wireguard VPN tunnel to link the two.

## Apps

* Jellyfin
* Pi-hole (local DNS + ad blocking)
* Immich (Someday)

## Local DNS (Pi-hole)

Pi-hole runs on the home node and serves DNS for the whole home network, so
traffic to hosted apps resolves to the home node and never leaves the LAN. It
also filters ads and trackers, forwarding unblocked queries to Quad9 (9.9.9.9).

* DNS: `53/tcp` and `53/udp` on the home node
* Web UI: `https://dns.$DOMAIN/admin` from LAN clients using Pi-hole for DNS
  (after the wildcard certificate is issued and Nginx is running)
* Last-resort local access on the home node: `http://127.0.0.1:8083/admin`
* Data: persisted in `local/.pihole/etc-pihole/` (gitignored)
* Config: `local/.env` (gitignored; copy from `local/.env.example`)

### First-time setup

1. Create your env file from the example and set the web UI password:

  ```bash
  cd local
  cp .env.example .env
  # then edit .env and set PIHOLE_PASSWORD to a real password
  ```

  `.env` is gitignored and must never be committed.

1. Start the container from [local](local):

  ```bash
  docker compose up -d pihole
  ```

1. Compose configures local DNS records for the hosted apps:

  ```text
  dns.$DOMAIN       ->  LAN_IP
  jellyfin.$DOMAIN  ->  LAN_IP
  ```

  Add future app records to `FTLCONF_dns_hosts` in `local/compose.yml`. Because
  this setting is managed by Compose, it is read-only in the Pi-hole UI; remove
  any duplicate records previously added through Local DNS → Records.

  On an existing node, apply the Compose changes with
  `docker compose up -d pihole nginx` from `local/` after the certificate is
  available.

1. Point your router's DHCP DNS at the home node IP so LAN clients use Pi-hole
   and can resolve `dns.$DOMAIN` to the home node. Clients will pick it up on
   their next DHCP lease renewal.

### Upstream and listening mode

* Upstream DNS is set via `FTLCONF_dns_upstreams=9.9.9.9` in
  [local/compose.yml](local/compose.yml).
* `FTLCONF_dns_listeningMode=ALL` is required because the container runs on
  Docker's default bridge network.
* The timezone is set via `TZ=America/Chicago`.
* Nginx serves the Pi-hole UI over HTTPS using the existing wildcard
  certificate; its direct HTTP fallback is bound to the homelab host only.

## Customizing for your own homelab

All site-specific values live in `local/.env` (copy from
[local/.env.example](local/.env.example)):

* `DOMAIN` — your base domain. Nginx server names and cert paths
  ([local/nginx/conf.d/jellyfin.conf](local/nginx/conf.d/jellyfin.conf)),
  Jellyfin's published URL, and the TLS scripts all read it. Set this before
  running anything.
* `PIHOLE_PASSWORD` — Pi-hole web UI password.

The only other place to update is the local DNS records you add in the
Pi-hole UI. TLS certs are issued via the Cloudflare API (see "TLS Cert
Workflow" below), so no manual DNS records are needed for cert issuance.

## Provisioning the home node

Clone the repo to a neutral, system-level location rather than a user home
directory — the cert renewal systemd timer runs
[local/scripts/renew-and-reload.sh](local/scripts/renew-and-reload.sh) by absolute
path as root, so the checkout shouldn't depend on a user account:

```bash
sudo mkdir -p /opt/homelab
sudo chown "$USER:$USER" /opt/homelab
git clone git@github.com:themooserooster/homelab.git /opt/homelab
cd /opt/homelab
```

[local/provision.sh](local/provision.sh)
prepares a fresh Ubuntu LTS host. It is idempotent — safe to re-run. Run it
as root after copying `.env.example` to `local/.env` and setting `DOMAIN`:

```bash
cd local
sudo ./provision.sh
```

It installs Docker Engine and the compose plugin, creates the host directories
the compose stack bind-mounts (`/etc/letsencrypt`, `/mnt/jellyfin/media/*`),
adds your user to the `docker` group, installs a systemd timer
(`certbot-renew.timer`, via
[local/scripts/install-cert-renew-timer.sh](local/scripts/install-cert-renew-timer.sh))
that runs `local/scripts/renew-and-reload.sh` twice daily for unattended cert
renewal, and installs `homelab-compose-update.timer`, which checks for and
applies container image updates every Sunday at 04:00 local time.

It then issues the initial TLS cert (see "TLS Cert Workflow" below): if
`/etc/letsencrypt/cloudflare.ini` doesn't exist yet, it prompts for a
Cloudflare API token (input hidden, file written root-only) and runs
[local/scripts/issue-initial-cert.sh](local/scripts/issue-initial-cert.sh).
Leave the prompt blank to skip issuance and do it later.

Because `/opt` directories are world-readable by default, tighten permissions
on the env file, which holds the Pi-hole password:

```bash
chmod 600 local/.env
```

## TLS Cert Workflow (Docker)

Certs are issued via DNS-01 challenge through the **Cloudflare API** — no
manual DNS records, and renewals are fully unattended. Certbot is configured
for one-shot runs from [local/compose.yml](local/compose.yml) (using the
`certbot/dns-cloudflare` image), and unattended renewal is driven by a host
scheduler (cron or systemd timer). This avoids granting the Certbot container
access to Docker socket.

### One-time Cloudflare setup

1. In the Cloudflare dashboard (My Profile → API Tokens), create a token with
   the **Zone → DNS → Edit** permission, scoped to the zone for `DOMAIN`.
1. Store it on the home node in `/etc/letsencrypt/cloudflare.ini`:

  ```bash
  echo 'dns_cloudflare_api_token = <token>' | sudo tee /etc/letsencrypt/cloudflare.ini
  sudo chmod 600 /etc/letsencrypt/cloudflare.ini
  ```

  The token can edit your DNS records but nothing else — keep the file
  root-only.

### Issuing and renewing

Provisioning issues the initial cert automatically (it prompts for the
Cloudflare token above if `/etc/letsencrypt/cloudflare.ini` is missing). Run
these commands from [local](local) only if you skipped issuance during
provisioning or need to re-issue:

1. Issue the initial cert (one-time) with DNS challenge. This wraps the
   Certbot run, verifies the cert files, starts Nginx, and makes sure
   unattended renewal is scheduled (installs the `certbot-renew.timer`
   systemd units if not already active). The email and domain are accepted
   via flags and prompted for if omitted; the domain prompt defaults to
   `DOMAIN` from `local/.env`:

  ```bash
  scripts/issue-initial-cert.sh --email you@example.com
  ```

  Or pass both explicitly:

  ```bash
  scripts/issue-initial-cert.sh --email you@example.com --domain your-domain.com
  ```

1. Unattended renewal is now scheduled — the `certbot-renew.timer` systemd
   timer runs [local/scripts/renew-and-reload.sh](local/scripts/renew-and-reload.sh)
   twice daily. It's installed by the provisioning script and (re-)checked by
   the issue script; to install or refresh it manually, run:

  ```bash
  scripts/install-cert-renew-timer.sh
  ```

  Renewal is fully automatic — the Cloudflare plugin creates and removes the
  TXT challenge records via the API, and Nginx is reloaded only when the cert
  actually renewed.

1. Optional cron example (runs at 03:17 and 15:17 daily) — or use the systemd
   timer installed by [local/scripts/install-cert-renew-timer.sh](local/scripts/install-cert-renew-timer.sh)
   (called by the provisioning and cert-issue scripts):

  ```bash
  17 3,15 * * * /opt/homelab/local/scripts/renew-and-reload.sh >> /var/log/certbot-renew.log 2>&1
  ```

1. Confirm renewal checks in logs.

  ```bash
  tail -n 100 /var/log/certbot-renew.log
  ```

Nginx currently expects (with `DOMAIN` set in `local/.env`):

* Certificate: /etc/letsencrypt/live/$DOMAIN/fullchain.pem
* Private key: /etc/letsencrypt/live/$DOMAIN/privkey.pem

## Boot behavior

No systemd unit is needed for the stack. Containers start automatically when
the machine boots:

* The Docker Engine packages installed by the provisioning script enable
  `docker.service` by default on Ubuntu, so the daemon comes up at boot.
* Every long-running service in [local/compose.yml](local/compose.yml)
  (jellyfin, wireguard, nginx, pihole) uses `restart: unless-stopped`, so the
  daemon restarts containers that were running before shutdown. No
  `docker compose up` is required after a reboot.

Notes:

* `unless-stopped` means a service you manually `docker compose stop` stays
  down across reboots.
* Nginx crash-loops until the initial cert exists (its config references
  `/etc/letsencrypt/live/$DOMAIN/`), which is why
  [local/scripts/issue-initial-cert.sh](local/scripts/issue-initial-cert.sh) starts
  nginx only after issuing the cert.
* Certbot is gated behind `profiles: [manual]`, so it never auto-starts; it
  runs one-shot via the scripts, driven by the host's `certbot-renew.timer`.

Verify on a running node:

```bash
docker inspect -f '{{.Name}} {{.HostConfig.RestartPolicy.Name}}' $(docker ps -aq)
systemctl is-enabled docker
```

## Automatic container updates

`homelab-compose-update.timer` runs
[local/scripts/update-compose-images.sh](local/scripts/update-compose-images.sh)
weekly on Sunday at 04:00 local time (with up to a five-minute randomized
delay). It pulls images for all Compose services, including the manual-only
Certbot image, then redeploys the default-profile services without starting
Certbot.
An updated image can briefly interrupt the affected service; automatic
rollback is not configured.

Check the next run and review the last run's logs with:

```bash
systemctl list-timers homelab-compose-update.timer
sudo journalctl -u homelab-compose-update.service
```

Run an update immediately with:

```bash
sudo systemctl start homelab-compose-update.service
```
