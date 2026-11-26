#!/usr/bin/env bash
set -euo pipefail

# Provision an Ubuntu LTS host for the home node:
#   - local/.env from .env.example (prompts for each value on first run)
#   - Docker Engine + compose plugin
#   - Host directories the compose stack bind-mounts
#   - Unattended cert renewal via a systemd timer
#     (see scripts/install-cert-renew-timer.sh)
#   - Initial TLS cert issuance (see scripts/issue-initial-cert.sh)
#   - Starts the Compose stack
#   - SSH, LAN-scoped firewall access, and automatic OS/container updates
#
# Run as root (from the local/ directory):
#   sudo ./provision.sh
#
# The repo is expected at /opt/homelab (see readme "Provisioning the home
# node"); the systemd timer runs the renewal script from wherever this
# checkout lives, so other locations work too.
#
# Idempotent: safe to re-run; SSH, firewall, and update policies are enforced.

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
LOCAL_DIR="$SCRIPT_DIR"
ENV_FILE="$LOCAL_DIR/.env"

log() { printf '\n==> %s\n' "$*"; }

if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: provision.sh must run as root (try: sudo $0)" >&2
  exit 1
fi

# $USER is "root" under sudo; these refer to the invoking user.
INVOKING_USER="${SUDO_USER:-$USER}"

# ------------------------------------------------------------- local/.env --
# First run: create .env from .env.example, prompting for each value.
if [ ! -f "$ENV_FILE" ]; then
  [ -f "$LOCAL_DIR/.env.example" ] ||
    { echo "ERROR: $LOCAL_DIR/.env.example not found." >&2; exit 1; }

  log "Creating $ENV_FILE from .env.example"
  echo "Press Enter to accept the [default]."

  while :; do
    read -r -p "Base domain, e.g. home.example.com: " DOMAIN \
      || { echo; echo "ERROR: input closed." >&2; exit 1; }
    [ -n "$DOMAIN" ] && break
    echo "  DOMAIN is required (nginx server names and cert paths use it)."
  done

  read -r -p "Home node's static IP on the LAN [192.168.1.166]: " HOMELAB_IP || HOMELAB_IP=""
  HOMELAB_IP="${HOMELAB_IP:-192.168.1.166}"

  read -r -p "Timezone [America/Chicago]: " TZ || TZ=""
  TZ="${TZ:-America/Chicago}"

  while :; do
    read -rs -p "Pi-hole web UI password (input hidden): " PIHOLE_PASSWORD \
      || { echo; echo "ERROR: input closed." >&2; exit 1; }
    echo
    [ -n "$PIHOLE_PASSWORD" ] && break
    echo "  A password is required (the example default is insecure)."
  done

  # Values go through the environment (not awk -v) so backslashes in them
  # survive; umask keeps the file private from the moment it's created.
  ( umask 077
    DOMAIN="$DOMAIN" HOMELAB_IP="$HOMELAB_IP" TZ="$TZ" PIHOLE_PASSWORD="$PIHOLE_PASSWORD" \
    awk '
      BEGIN { split("DOMAIN HOMELAB_IP TZ PIHOLE_PASSWORD", keys, " ") }
      {
        for (i = 1; i <= 4; i++)
          if (index($0, keys[i] "=") == 1) { print keys[i] "=" ENVIRON[keys[i]]; next }
        print
      }
    ' "$LOCAL_DIR/.env.example" > "$ENV_FILE"
  )
  chown "$INVOKING_USER:$INVOKING_USER" "$ENV_FILE"
  chmod 600 "$ENV_FILE"

  # Fail loudly if .env.example and the prompt list ever drift apart.
  for key in DOMAIN HOMELAB_IP TZ PIHOLE_PASSWORD; do
    if ! grep -q "^$key=" "$ENV_FILE"; then
      echo "ERROR: $key missing from $ENV_FILE; update the prompt list in $0." >&2
      exit 1
    fi
  done
  echo "Wrote $ENV_FILE."
fi

# DOMAIN comes from local/.env (cert paths depend on it).
DOMAIN="$(grep -E '^DOMAIN=' "$ENV_FILE" | tail -n1 | cut -d= -f2-)"
: "${DOMAIN:?DOMAIN must be set in local/.env (delete it to redo the setup prompts)}"
HOMELAB_IP="$(grep -E '^HOMELAB_IP=' "$ENV_FILE" | tail -n1 | cut -d= -f2-)"

# -------------------------------------------------------- SSH and firewall
log "Installing OpenSSH Server, UFW, and unattended-upgrades"
apt-get update
apt-get install -y openssh-server ufw unattended-upgrades
systemctl enable --now ssh

# Harden SSH: key-only auth, no root login. The invoking user's authorized_keys
# must already be in place (or password auth will be locked out).
log "Hardening SSH (key-only auth, no root login)"
install -d -m 0755 /etc/ssh/sshd_config.d
tee /etc/ssh/sshd_config.d/90-homelab.conf > /dev/null <<'EOF'
PasswordAuthentication no
PermitRootLogin no
PubkeyAuthentication yes
KbdInteractiveAuthentication no
EOF
systemctl reload ssh

# The Wireguard tunnel to the edge VPS (see local/wireguard/wg0.conf). The
# edge node reaches this host through it, so it needs the same access as the
# LAN for the ports the edge proxies.
WG_CIDR="10.0.0.0/24"

if ! ROUTE="$(ip -4 route get 1.1.1.1 2>/dev/null)"; then
  echo "Error: unable to determine the active LAN IPv4 route." >&2
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
log "Allowing SSH from $LAN_CIDR and $WG_CIDR"
ufw allow from "$LAN_CIDR" to any port 22 proto tcp
ufw allow from "$WG_CIDR" to any port 22 proto tcp

# App ports, reachable from the LAN. Docker publishes ports via iptables,
# which bypasses UFW's INPUT chain, so these rules are belt and braces — but
# they keep the policy honest if Docker's iptables handling ever changes.
# The app ports are bound to HOMELAB_IP in compose.yml, so the tunnel can't
# reach them; only the all-interfaces ports (22, 80, 443, 51820/udp) get
# tunnel rules.
log "Allowing app ports from $LAN_CIDR"
for port in 80 443 8096 8083; do
  ufw allow from "$LAN_CIDR" to any port "$port" proto tcp
done
ufw allow from "$LAN_CIDR" to any port 53 proto tcp
ufw allow from "$LAN_CIDR" to any port 53 proto udp
ufw allow from "$LAN_CIDR" to any port 51820 proto udp
log "Allowing tunnel access to 80, 443, 51820/udp from $WG_CIDR"
ufw allow from "$WG_CIDR" to any port 80 proto tcp
ufw allow from "$WG_CIDR" to any port 443 proto tcp
ufw allow from "$WG_CIDR" to any port 51820 proto udp

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

# Docker publishes ports via iptables (DOCKER chain), which is evaluated
# before UFW's INPUT chain — so `ufw default deny incoming` does NOT block
# Docker-published ports. Bind app ports to HOMELAB_IP in compose.yml (done)
# and add explicit DOCKER-USER rules so the tunnel/LAN scoping is enforced
# even for Docker-published ports.
log "Installing DOCKER-USER iptables rules for LAN/tunnel scoping"
apt-get install -y iptables-persistent
# Allow established/related, loopback, LAN, and tunnel; drop the rest.
# Docker's DOCKER-USER chain is jumped to before DOCKER, so this gates all
# Docker-published ports.
for rule in \
  "-m conntrack --ctstate ESTABLISHED,RELATED -j RETURN" \
  "-i lo -j RETURN" \
  "-s $LAN_CIDR -j RETURN" \
  "-s $WG_CIDR -j RETURN" \
  "-j DROP"; do
  iptables -C DOCKER-USER $rule 2>/dev/null || iptables -I DOCKER-USER $rule
done
netfilter-persistent save

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

# --------------------------------------------------------- Start the stack --
log "Starting the Compose stack"
(cd "$LOCAL_DIR" && docker compose up -d)

log "Provisioning complete for domain: $DOMAIN"
echo "  - Stack: docker compose ps"
echo "  - Renewal timer: systemctl list-timers certbot-renew.timer"
echo "  - Compose update timer: systemctl list-timers homelab-compose-update.timer"
echo "  - Next: point your router's DHCP DNS at $HOMELAB_IP (see readme 'Local DNS')"
echo "  - If you were added to the docker group, log out and back in first."
