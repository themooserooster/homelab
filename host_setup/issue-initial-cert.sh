#!/bin/sh
set -eu

# Issue the initial wildcard cert via the Certbot container (DNS-01 challenge
# through the Cloudflare API), then start Nginx so it picks the cert up.
#
# Requires /etc/letsencrypt/cloudflare.ini with a Cloudflare API token scoped
# to Zone > DNS > Edit for the domain's zone (see readme "TLS Cert Workflow").
#
# Usage: issue-initial-cert.sh --email <email> [--domain <domain>]
#   --email / -e    Let's Encrypt account email (prompted if not given)
#   --domain / -d   base domain (prompted if not given; a wildcard for the
#                   domain is always requested alongside it)
#   --help / -h / -?  print this help and exit

# Print the leading comment block (front matter) as help text.
print_help() {
  awk 'NR > 3 && /^#/{ sub(/^# ?/, ""); print; next } NR > 3 && !/^#/{ exit }' "$0"
}

EMAIL=""
DOMAIN=""

while [ $# -gt 0 ]; do
  case "$1" in
    --help|-h|-\?)
      print_help
      exit 0 ;;
    --email|-e)
      [ $# -ge 2 ] || { echo "ERROR: $1 requires a value" >&2; exit 1; }
      EMAIL="$2"; shift 2 ;;
    --domain|-d)
      [ $# -ge 2 ] || { echo "ERROR: $1 requires a value" >&2; exit 1; }
      DOMAIN="$2"; shift 2 ;;
    *)
      echo "Usage: $0 --email <email> [--domain <domain>]" >&2
      echo "  --email / -e    Let's Encrypt account email" >&2
      echo "  --domain / -d   base domain (default: \$DOMAIN from local/.env)" >&2
      echo "  --help / -h / -?  print this help and exit" >&2
      exit 1 ;;
  esac
done

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
LOCAL_DIR="$REPO_DIR/local"
ENV_FILE="$LOCAL_DIR/.env"

if [ -z "$DOMAIN" ]; then
  if [ -f "$ENV_FILE" ]; then
    # shellcheck disable=SC1090
    ENV_DOMAIN="$(set -a && . "$ENV_FILE" && set +a && echo "$DOMAIN")"
  fi
  if [ -n "${ENV_DOMAIN:-}" ]; then
    printf "Domain [%s]: " "$ENV_DOMAIN"
    read -r REPLY
    DOMAIN="${REPLY:-$ENV_DOMAIN}"
  else
    printf "Domain: "
    read -r DOMAIN
  fi
  if [ -z "$DOMAIN" ]; then
    echo "ERROR: no domain given." >&2
    exit 1
  fi
fi

if [ -z "$EMAIL" ]; then
  printf "Email for Let's Encrypt account: "
  read -r EMAIL
  if [ -z "$EMAIL" ]; then
    echo "ERROR: no email given." >&2
    exit 1
  fi
fi

LIVE_DIR="/etc/letsencrypt/live/$DOMAIN"
CF_INI="/etc/letsencrypt/cloudflare.ini"

if [ ! -f "$CF_INI" ]; then
  echo "ERROR: $CF_INI not found." >&2
  echo "Create it with your Cloudflare API token (see readme 'TLS Cert Workflow'):" >&2
  echo "  echo 'dns_cloudflare_api_token = <token>' | sudo tee $CF_INI" >&2
  echo "  sudo chmod 600 $CF_INI" >&2
  exit 1
fi

cd "$LOCAL_DIR"

echo "Issuing cert for $DOMAIN and *.$DOMAIN (account: $EMAIL)..."
docker compose run --rm --entrypoint certbot certbot certonly \
  --dns-cloudflare \
  --dns-cloudflare-credentials "$CF_INI" \
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
