#!/bin/sh
set -eu

# Install (or refresh) the weekly systemd timer that updates the Compose stack.
# Called by ../provision.sh; can also be run standalone. Needs root —
# uses sudo when invoked as a non-root user.

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
UPDATE_SCRIPT="$SCRIPT_DIR/update-compose-images.sh"

if [ ! -f "$UPDATE_SCRIPT" ]; then
  echo "ERROR: $UPDATE_SCRIPT not found." >&2
  exit 1
fi

SUDO=""
if [ "$(id -u)" -ne 0 ]; then
  SUDO="sudo"
fi

$SUDO chmod +x "$UPDATE_SCRIPT"

$SUDO tee /etc/systemd/system/homelab-compose-update.service > /dev/null <<EOF
[Unit]
Description=Update home node Docker Compose images
Wants=network-online.target docker.service
After=network-online.target docker.service

[Service]
Type=oneshot
TimeoutStartSec=30min
ExecStart=$UPDATE_SCRIPT
EOF

$SUDO tee /etc/systemd/system/homelab-compose-update.timer > /dev/null <<'EOF'
[Unit]
Description=Update home node Docker Compose images weekly

[Timer]
OnCalendar=Sun *-*-* 04:00:00
RandomizedDelaySec=300
Persistent=true

[Install]
WantedBy=timers.target
EOF

$SUDO systemctl daemon-reload
$SUDO systemctl enable --now homelab-compose-update.timer

echo "Installed homelab-compose-update.timer (weekly, Sunday at 04:00 local time)."
echo "Check the schedule with: systemctl list-timers homelab-compose-update.timer"
