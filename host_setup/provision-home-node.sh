#!/usr/bin/env bash
set -euo pipefail

# Provision an Ubuntu LTS host for the home node:
#   - Docker Engine + compose plugin
#   - Host directories the compose stack bind-mounts
#   - Unattended cert renewal via a systemd timer
#     (see install-cert-renew-timer.sh)
#
# Run as a user with sudo access:
#   ./provision-home-node.sh
#
# The repo is expected at /opt/homelab (see readme "Provisioning the home
# node"); the systemd timer runs the renewal script from wherever this
# checkout lives, so other locations work too.
#
# Idempotent: safe to re-run; SSH and firewall policy is enforced on each run.

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
LOCAL_DIR="$REPO_DIR/local"

# DOMAIN comes from local/.env (cert paths depend on it).
DOMAIN="$(grep -E '^DOMAIN=' "$LOCAL_DIR/.env" | tail -n1 | cut -d= -f2-)"
: "${DOMAIN:?DOMAIN must be set in local/.env (copy .env.example if needed)}"

log() { printf '\n==> %s\n' "$*"; }

SUDO=""
if [ "$(id -u)" -ne 0 ]; then
  SUDO="sudo"
fi

# -------------------------------------------------------- SSH and firewall
log "Installing OpenSSH Server and UFW"
$SUDO apt-get update
$SUDO apt-get install -y openssh-server ufw
$SUDO systemctl enable --now ssh

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
$SUDO ufw allow from "$LAN_CIDR" to any port 22 proto tcp

# Existing unrestricted SSH rules would override the LAN-only rule.
remove_unrestricted_ssh_rules() {
  local status number
  local -a rules=()
  local i

  status="$($SUDO ufw status numbered)"
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
    $SUDO ufw --force delete "${rules[$i]}"
  done
}
remove_unrestricted_ssh_rules

$SUDO ufw default deny incoming
$SUDO ufw default allow outgoing
$SUDO ufw --force enable

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
"$SCRIPT_DIR/install-cert-renew-timer.sh"

log "Provisioning complete for domain: $DOMAIN"
echo "  - Renewal timer: systemctl list-timers certbot-renew.timer"
echo "  - Next: issue the initial cert (see readme 'TLS Cert Workflow'):"
echo "      cd $LOCAL_DIR && ../host_setup/issue-initial-cert.sh --email you@example.com"
echo "  - If you were added to the docker group, log out and back in first."
