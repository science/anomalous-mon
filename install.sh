#!/usr/bin/env bash
# install.sh — Install anomalous-mon as a systemd user timer
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_DIR="${HOME}/.config/systemd/user"

mkdir -p "$SERVICE_DIR"

cat > "$SERVICE_DIR/anomalous-mon.service" << EOF
[Unit]
Description=Desktop anomaly monitor

[Service]
Type=oneshot
ExecStart=${SCRIPT_DIR}/bin/anomalous-mon
EOF

cat > "$SERVICE_DIR/anomalous-mon.timer" << EOF
[Unit]
Description=Run anomalous-mon continuously

[Timer]
OnBootSec=10
OnUnitInactiveSec=5
AccuracySec=5

[Install]
WantedBy=timers.target
EOF

chmod +x "$SCRIPT_DIR/bin/anomalous-mon"

systemctl --user daemon-reload
systemctl --user enable --now anomalous-mon.timer

echo "anomalous-mon installed and timer started."
echo "Check status: systemctl --user status anomalous-mon.timer"
echo "View logs:    journalctl --user -u anomalous-mon -f"
