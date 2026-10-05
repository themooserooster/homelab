#!/usr/bin/env bash
set -euo pipefail

# Provision an Ubuntu LTS host for the home node:
#   - Docker Engine + compose plugin
#   - Host directories the compose stack bind-mounts
#   - Unattended cert renewal via a systemd timer
#
# Run as a user with sudo access:
#   ./provision-home-node.sh
#
# The repo is expected at /opt/homelab (see readme "Provisioning the home
# node"); the systemd timer runs the renewal script from wherever this
# checkout lives, so other locations work too.
#
# Idempotent: safe to re-run; existing state is left alone.

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
LOCAL_DIR="$REPO_DIR/local"

# DOMAIN comes from local/.env (cert paths depend on it). UID/GID in .env are
# informational; UID is readonly in bash so only DOMAIN is extracted here.
DOMAIN="$(grep -E '^DOMAIN=' "$LOCAL_DIR/.env" | tail -n1 | cut -d= -f2-)"
: "${DOMAIN:?DOMAIN must be set in local/.env (copy .env.example if needed)}"

log() { printf '\n==> %s\n' "$*"; }

SUDO=""
if [ "$(id -u)" -ne 0 ]; then
  SUDO="sudo"
fi

# ---------------------------------------------------------------- Docker ---
log "Installing Docker Engine and compose plugin"
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  echo "Docker and compose already installed, skipping."
else
  $SUDO apt-get update
  $SUDO apt-get install -y ca-certificates curl
  $SUDO install -m 0755 -d /etc/apt/keyrings
  $SUDO curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    -o /etc/apt/keyrings/docker.asc
  $SUDO chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" |
    $SUDO tee /etc/apt/sources.list.d/docker.list > /dev/null
  $SUDO apt-get update
  $SUDO apt-get install -y docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin
fi

# Run docker without sudo for the invoking user.
if [ "$(id -u)" -ne 0 ] && ! id -nG "$USER" | grep -qw docker; then
  log "Adding $USER to the docker group (takes effect on next login)"
  $SUDO usermod -aG docker "$USER"
fi

# ---------------------------------------------------- Host directories ----
log "Creating host directories for bind mounts"
# Certbot state (nginx mounts it read-only; certbot needs write access).
$SUDO mkdir -p /etc/letsencrypt /var/lib/letsencrypt /var/log/letsencrypt
# Jellyfin media — adjust layout to taste; compose expects these paths.
$SUDO mkdir -p /mnt/jellyfin/media/music /mnt/jellyfin/media/movies /mnt/jellyfin/media/tv
# Let the invoking user (and containers via UID mapping) manage media.
$SUDO chown -R "$USER:$USER" /mnt/jellyfin

# ------------------------------------------------- Cert renewal timer -----
log "Installing cert renewal systemd units"
RENEW_SCRIPT="$SCRIPT_DIR/renew-and-reload.sh"

$SUDO tee /etc/systemd/system/certbot-renew.service > /dev/null <<EOF
[Unit]
Description=Renew Let's Encrypt certs and reload nginx
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=$RENEW_SCRIPT
EOF

$SUDO tee /etc/systemd/system/certbot-renew.timer > /dev/null <<'EOF'
[Unit]
Description=Run cert renewal twice daily

[Timer]
# 03:17 and 15:17 local time, matching the readme's cron example.
OnCalendar=*-*-* 03,15:17:00
RandomizedDelaySec=300
Persistent=true

[Install]
WantedBy=timers.target
EOF

$SUDO chmod +x "$RENEW_SCRIPT"
$SUDO systemctl daemon-reload
$SUDO systemctl enable --now certbot-renew.timer

log "Provisioning complete for domain: $DOMAIN"
echo "  - Renewal timer: systemctl list-timers certbot-renew.timer"
echo "  - Next: issue the initial cert (see readme 'TLS Cert Workflow'):"
echo "      cd $LOCAL_DIR && ../host_setup/issue-initial-cert.sh --email you@example.com"
echo "  - If you were added to the docker group, log out and back in first."
