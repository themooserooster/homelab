#!/bin/sh
set -eu

# Issue the initial wildcard cert via the Certbot container (DNS-01 challenge
# through acme-dns), then start Nginx so it picks the cert up.
#
# Usage: issue-initial-cert.sh <email> [domain]
#   email  - Let's Encrypt account email (required)
#   domain - base domain (optional; defaults to $DOMAIN from local/.env).
#            A wildcard for the domain is always requested alongside it.

if [ $# -lt 1 ] || [ $# -gt 2 ]; then
  echo "Usage: $0 <email> [domain]" >&2
  echo "  email  - Let's Encrypt account email" >&2
  echo "  domain - base domain (default: \$DOMAIN from local/.env)" >&2
  exit 1
fi

EMAIL="$1"
DOMAIN="${2:-}"

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
LOCAL_DIR="$REPO_DIR/local"
ENV_FILE="$LOCAL_DIR/.env"

if [ -z "$DOMAIN" ]; then
  if [ ! -f "$ENV_FILE" ]; then
    echo "ERROR: no domain given and $ENV_FILE not found." >&2
    echo "Pass a domain as the second argument or create $ENV_FILE (see .env.example)." >&2
    exit 1
  fi
  # shellcheck disable=SC1090
  DOMAIN="$(set -a && . "$ENV_FILE" && set +a && echo "$DOMAIN")"
  if [ -z "$DOMAIN" ]; then
    echo "ERROR: DOMAIN is not set in $ENV_FILE." >&2
    exit 1
  fi
fi

LIVE_DIR="/etc/letsencrypt/live/$DOMAIN"

cd "$LOCAL_DIR"

echo "Issuing cert for $DOMAIN and *.$DOMAIN (account: $EMAIL)..."
docker compose run --rm --entrypoint certbot certbot certonly \
  --manual \
  --manual-auth-hook /opt/certbot/acme-dns-auth.py \
  --preferred-challenges dns \
  --manual-public-ip-logging-ok \
  --non-interactive \
  --agree-tos \
  -m "$EMAIL" \
  -d "$DOMAIN" \
  -d "*.$DOMAIN"

if [ ! -d "$LIVE_DIR" ]; then
  echo "ERROR: expected cert directory $LIVE_DIR was not created." >&2
  exit 1
fi
echo "Cert files:"
ls "$LIVE_DIR"

echo "Starting/recreating Nginx to read the new cert..."
docker compose up -d --force-recreate nginx

echo
echo "Done. Configure unattended renewal with the host scheduler:"
echo "  $SCRIPT_DIR/renew-and-reload.sh"
