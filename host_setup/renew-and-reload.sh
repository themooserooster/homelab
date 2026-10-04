#!/bin/sh
set -eu

# Run from anywhere; this resolves repo paths relative to this script.
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
LOCAL_DIR="$REPO_DIR/local"
FLAG_FILE="/var/lib/letsencrypt/.cert_renewed"

cd "$LOCAL_DIR"

# Clear stale renewal flag before running.
rm -f "$FLAG_FILE"

docker compose run --rm certbot renew \
  --manual \
  --preferred-challenges dns \
  --manual-auth-hook /opt/certbot/acme-dns-auth.py \
  --manual-public-ip-logging-ok \
  --non-interactive \
  --deploy-hook "sh -c 'touch /var/lib/letsencrypt/.cert_renewed'"

if [ -f "$FLAG_FILE" ]; then
  docker compose exec -T nginx nginx -s reload
  rm -f "$FLAG_FILE"
fi
