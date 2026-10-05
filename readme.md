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
* Web UI: `http://<home-node-ip>:8083/admin` (nginx keeps 80/443, so Pi-hole's
  UI is on an alternate port)
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

1. Log in to the web UI and add local DNS records so hosted apps resolve to the
   home node on the LAN (Web UI → Local DNS → Records), e.g.:

  ```text
  jellyfin.$DOMAIN  ->  <home-node-ip>
  ```

1. Point your router's DHCP DNS at the home node IP so all LAN clients use
   Pi-hole. Clients will pick it up on their next DHCP lease renewal.

### Upstream and listening mode

* Upstream DNS is set via `FTLCONF_dns_upstreams=9.9.9.9` in
  [local/compose.yml](local/compose.yml).
* `FTLCONF_dns_listeningMode=ALL` is required because the container runs on
  Docker's default bridge network.
* The timezone is set via `TZ=America/Chicago`.

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
[host_setup/renew-and-reload.sh](host_setup/renew-and-reload.sh) by absolute
path as root, so the checkout shouldn't depend on a user account:

```bash
sudo mkdir -p /opt/homelab
sudo chown "$USER:$USER" /opt/homelab
git clone git@github.com:themooserooster/homelab.git /opt/homelab
cd /opt/homelab
```

[host_setup/provision-home-node.sh](host_setup/provision-home-node.sh)
prepares a fresh Ubuntu LTS host. It is idempotent — safe to re-run. Run it
after copying `.env.example` to `local/.env` and setting `DOMAIN`:

```bash
./host_setup/provision-home-node.sh
```

It installs Docker Engine and the compose plugin, creates the host directories
the compose stack bind-mounts (`/etc/letsencrypt`, `/mnt/jellyfin/media/*`),
adds your user to the `docker` group, and installs a systemd timer
(`certbot-renew.timer`) that runs `host_setup/renew-and-reload.sh` twice
daily for unattended cert renewal.

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

Run these commands from [local](local):

1. Issue the initial cert (one-time) with DNS challenge. This wraps the
   Certbot run, verifies the cert files, and starts Nginx. The email and
   domain are accepted via flags and prompted for if omitted; the domain
   prompt defaults to `DOMAIN` from `local/.env`:

  ```bash
  ../host_setup/issue-initial-cert.sh --email you@example.com
  ```

  Or pass both explicitly:

  ```bash
  ../host_setup/issue-initial-cert.sh --email you@example.com --domain your-domain.com
  ```

1. Configure unattended renewal from host scheduler (recommended secure option).

  ```bash
  ../host_setup/renew-and-reload.sh
  ```

  Renewal is fully automatic — the Cloudflare plugin creates and removes the
  TXT challenge records via the API, and Nginx is reloaded only when the cert
  actually renewed.

1. Optional cron example (runs at 03:17 and 15:17 daily) — or use the systemd
   timer installed by the provisioning script:

  ```bash
  17 3,15 * * * /opt/homelab/host_setup/renew-and-reload.sh >> /var/log/certbot-renew.log 2>&1
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
  [host_setup/issue-initial-cert.sh](host_setup/issue-initial-cert.sh) starts
  nginx only after issuing the cert.
* Certbot is gated behind `profiles: [manual]`, so it never auto-starts; it
  runs one-shot via the scripts, driven by the host's `certbot-renew.timer`.

Verify on a running node:

```bash
docker inspect -f '{{.Name}} {{.HostConfig.RestartPolicy.Name}}' $(docker ps -aq)
systemctl is-enabled docker
```
