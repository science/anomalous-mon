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

# Stale-files: weekly out-of-band scan. Independent service/timer pair so a
# slow filesystem walk never blocks the 5s monitoring loop.
cat > "$SERVICE_DIR/anomalous-mon-stale.service" << EOF
[Unit]
Description=Weekly stale large-files scan

[Service]
Type=oneshot
Nice=19
IOSchedulingClass=idle
TimeoutStartSec=30min
ExecStart=${SCRIPT_DIR}/bin/anomalous-mon --stale-scan
EOF

cat > "$SERVICE_DIR/anomalous-mon-stale.timer" << EOF
[Unit]
Description=Weekly stale large-files scan

[Timer]
OnCalendar=Mon 03:00
Persistent=true
RandomizedDelaySec=2h

[Install]
WantedBy=timers.target
EOF

chmod +x "$SCRIPT_DIR/bin/anomalous-mon"

systemctl --user daemon-reload
systemctl --user enable --now anomalous-mon.timer
systemctl --user enable --now anomalous-mon-stale.timer

# Kick a one-shot first stale scan so the user gets immediate feedback
# instead of waiting up to a week. Backgrounded so install returns quickly.
systemctl --user start --no-block anomalous-mon-stale.service

echo "anomalous-mon installed and timers started."
echo "Check status:   systemctl --user status anomalous-mon.timer"
echo "Stale-files:    systemctl --user list-timers anomalous-mon-stale.timer"
echo "View logs:      journalctl --user -u anomalous-mon -f"
echo "Stale report:   anomalous-mon --stale-report  (after first scan completes)"
