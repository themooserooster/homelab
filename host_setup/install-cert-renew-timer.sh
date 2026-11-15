#!/bin/sh
set -eu

# Install (or refresh) the host systemd units that run renew-and-reload.sh
# twice daily for unattended Let's Encrypt cert renewal, then enable the
# timer. Idempotent: safe to re-run; unit files are rewritten and the timer
# re-enabled.
#
# Called by provision-home-node.sh and issue-initial-cert.sh; can also be run
# standalone. Needs root — uses sudo when invoked as a non-root user.

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
RENEW_SCRIPT="$SCRIPT_DIR/renew-and-reload.sh"

if [ ! -f "$RENEW_SCRIPT" ]; then
  echo "ERROR: $RENEW_SCRIPT not found." >&2
  exit 1
fi

SUDO=""
if [ "$(id -u)" -ne 0 ]; then
  SUDO="sudo"
fi

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

echo "Installed certbot-renew.timer (runs $RENEW_SCRIPT twice daily)."
echo "Check the schedule with: systemctl list-timers certbot-renew.timer"
