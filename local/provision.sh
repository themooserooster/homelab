#!/usr/bin/env bash
set -euo pipefail

# Provision an Ubuntu LTS host for the home node:
#   - Docker Engine + compose plugin
#   - Host directories the compose stack bind-mounts
#   - Unattended cert renewal via a systemd timer
#     (see scripts/install-cert-renew-timer.sh)
#   - Initial TLS cert issuance (see scripts/issue-initial-cert.sh)
#   - SSH, LAN-scoped firewall access, lid-close behavior, and automatic
#     OS/container updates
#
# Run as root (from the local/ directory):
#   sudo ./provision.sh
#
# The repo is expected at /opt/homelab (see readme "Provisioning the home
# node"); the systemd timer runs the renewal script from wherever this
# checkout lives, so other locations work too.
#
# Idempotent: safe to re-run; SSH, firewall, lid, and update policies are enforced.

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
LOCAL_DIR="$SCRIPT_DIR"

# DOMAIN comes from local/.env (cert paths depend on it).
DOMAIN="$(grep -E '^DOMAIN=' "$LOCAL_DIR/.env" | tail -n1 | cut -d= -f2-)"
: "${DOMAIN:?DOMAIN must be set in local/.env (copy .env.example if needed)}"

log() { printf '\n==> %s\n' "$*"; }

if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: provision.sh must run as root (try: sudo $0)" >&2
  exit 1
fi

# $USER is "root" under sudo; these refer to the invoking user.
INVOKING_USER="${SUDO_USER:-$USER}"

# -------------------------------------------------------- SSH and firewall
log "Installing OpenSSH Server, UFW, and unattended-upgrades"
apt-get update
apt-get install -y openssh-server ufw unattended-upgrades
systemctl enable --now ssh

if ! ROUTE="$(ip -4 route get 1.1.1.1 2>/dev/null)"; then
  echo "Error: unable to determine the active LAN IPv4 route for SSH." >&2
  exit 1
fi
LAN_IFACE="$(awk '{for (i = 1; i <= NF; i++) if ($i == "dev") {print $(i + 1); exit}}' <<< "$ROUTE")"
LAN_SOURCE="$(awk '{for (i = 1; i <= NF; i++) if ($i == "src") {print $(i + 1); exit}}' <<< "$ROUTE")"
if [ -z "$LAN_IFACE" ] || [ -z "$LAN_SOURCE" ]; then
  echo "Error: unable to determine the active LAN interface and address for SSH." >&2
  exit 1
fi
LAN_CIDR="$(ip -4 route show dev "$LAN_IFACE" proto kernel scope link |
  awk -v source="$LAN_SOURCE" '
    {
      for (i = 1; i < NF; i++) {
        if ($i == "src" && $(i + 1) == source) {
          print $1
          exit
        }
      }
    }')"
if [ -z "$LAN_CIDR" ]; then
  echo "Error: unable to determine the connected LAN subnet for $LAN_IFACE ($LAN_SOURCE)." >&2
  exit 1
fi
log "Restricting SSH access to $LAN_CIDR"
ufw allow from "$LAN_CIDR" to any port 22 proto tcp

# Existing unrestricted SSH rules would override the LAN-only rule.
remove_unrestricted_ssh_rules() {
  local status number
  local -a rules=()
  local i

  status="$(ufw status numbered)"
  while IFS= read -r number; do
    [ -n "$number" ] && rules+=("$number")
  done < <(
    awk '
      /^\[[[:space:]]*[0-9]+\]/ && /ALLOW IN/ && /Anywhere/ {
        number = $0
        sub(/^\[[[:space:]]*/, "", number)
        sub(/\].*/, "", number)
        rule = $0
        sub(/^\[[[:space:]]*[0-9]+\][[:space:]]*/, "", rule)
        if (rule ~ /^OpenSSH([[:space:]]|$)/ || rule ~ /^22(\/tcp)?([[:space:]]|$)/) {
          print number
        }
      }
    ' <<< "$status"
  )

  for ((i = ${#rules[@]} - 1; i >= 0; i--)); do
    ufw --force delete "${rules[$i]}"
  done
}
remove_unrestricted_ssh_rules

ufw default deny incoming
ufw default allow outgoing
ufw --force enable

# --------------------------------------------------- Automatic updates ----
log "Enabling daily unattended upgrades"
tee /etc/apt/apt.conf.d/52-homelab-auto-upgrades > /dev/null <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
systemctl enable --now apt-daily.timer apt-daily-upgrade.timer

# ---------------------------------------------------------------- Docker ---
log "Installing Docker Engine and compose plugin"
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  echo "Docker and compose already installed, skipping."
else
  apt-get update
  apt-get install -y ca-certificates curl
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" |
    tee /etc/apt/sources.list.d/docker.list > /dev/null
  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin
fi

# Run docker without sudo for the invoking user.
if ! id -nG "$INVOKING_USER" | grep -qw docker; then
  log "Adding $INVOKING_USER to the docker group (takes effect on next login)"
  usermod -aG docker "$INVOKING_USER"
fi

# ---------------------------------------------------- Host directories ----
log "Creating host directories for bind mounts"
# Certbot state (nginx mounts it read-only; certbot needs write access).
mkdir -p /etc/letsencrypt /var/lib/letsencrypt /var/log/letsencrypt
# Jellyfin media — adjust layout to taste; compose expects these paths.
mkdir -p /mnt/jellyfin/media/music /mnt/jellyfin/media/movies /mnt/jellyfin/media/tv
# Let the invoking user (and containers via UID mapping) manage media.
chown -R "$INVOKING_USER:$INVOKING_USER" /mnt/jellyfin

# ------------------------------------------------- Cert renewal timer -----
log "Installing cert renewal systemd units"
"$SCRIPT_DIR/scripts/install-cert-renew-timer.sh"

# ------------------------------------------------ Compose update timer -----
log "Installing weekly Compose image update timer"
"$SCRIPT_DIR/scripts/install-compose-update-timer.sh"

# ------------------------------------------------------- Initial TLS cert --
CERT_DIR="/etc/letsencrypt/live/$DOMAIN"
CF_INI="/etc/letsencrypt/cloudflare.ini"

if [ -d "$CERT_DIR" ]; then
  log "Cert for $DOMAIN already exists, skipping issuance"
else
  log "Issuing the initial TLS cert for $DOMAIN"
  if [ ! -f "$CF_INI" ]; then
    echo "A Cloudflare API token with Zone > DNS > Edit access to $DOMAIN is"
    echo "needed for DNS-01 cert issuance. Create one in the Cloudflare"
    echo "dashboard (My Profile > API Tokens)."
    printf "Cloudflare API token (blank to skip cert issuance): "
    read -rs CF_TOKEN || CF_TOKEN=""
    echo
    if [ -n "$CF_TOKEN" ]; then
      # Private from creation onward, even briefly.
      ( umask 077; printf 'dns_cloudflare_api_token = %s\n' "$CF_TOKEN" > "$CF_INI" )
    fi
  fi
  if [ ! -f "$CF_INI" ]; then
    echo "No Cloudflare token provided; skipping cert issuance. Once the token"
    echo "is in $CF_INI, run: scripts/issue-initial-cert.sh --email you@example.com"
  else
    "$SCRIPT_DIR/scripts/issue-initial-cert.sh" --domain "$DOMAIN"
  fi
fi

# ------------------------------------------------------- Lid-close behavior
log "Configuring lid-close behavior (restarting logind may interrupt active sessions)"
install -d -m 0755 /etc/systemd/logind.conf.d
tee /etc/systemd/logind.conf.d/90-homelab-lid.conf > /dev/null <<'EOF'
[Login]
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
HandleLidSwitchDocked=ignore
EOF
systemctl restart systemd-logind

log "Provisioning complete for domain: $DOMAIN"
echo "  - Renewal timer: systemctl list-timers certbot-renew.timer"
echo "  - Compose update timer: systemctl list-timers homelab-compose-update.timer"
echo "  - If you were added to the docker group, log out and back in first."
