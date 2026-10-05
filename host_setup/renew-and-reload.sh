#!/bin/sh
set -eu

# Renew Let's Encrypt certs via the Certbot container (Cloudflare DNS-01) and
# reload Nginx if the cert was renewed. Driven by the host's
# certbot-renew.timer; safe to run manually.
#
# Run from anywhere; this resolves repo paths relative to this script.
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
LOCAL_DIR="$REPO_DIR/local"
FLAG_FILE="/var/lib/letsencrypt/.cert_renewed"

cd "$LOCAL_DIR"

# Clear stale renewal flag before running.
rm -f "$FLAG_FILE"

docker compose run --rm certbot renew \
  --dns-cloudflare \
  --dns-cloudflare-credentials /etc/letsencrypt/cloudflare.ini \
  --non-interactive \
  --deploy-hook "sh -c 'touch /var/lib/letsencrypt/.cert_renewed'"

if [ -f "$FLAG_FILE" ]; then
  docker compose exec -T nginx nginx -s reload
  rm -f "$FLAG_FILE"
fi
