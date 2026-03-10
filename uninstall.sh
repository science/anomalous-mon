#!/usr/bin/env bash
# uninstall.sh — Remove anomalous-mon systemd user timer and service
set -euo pipefail

SERVICE_DIR="${HOME}/.config/systemd/user"

systemctl --user disable --now anomalous-mon.timer 2>/dev/null || true
rm -f "$SERVICE_DIR/anomalous-mon.service" "$SERVICE_DIR/anomalous-mon.timer"
systemctl --user daemon-reload

# Clean up runtime state
STATE_DIR="${XDG_RUNTIME_DIR:-/tmp}"
rm -f "${STATE_DIR}/anomalous-mon.state" "${STATE_DIR}/anomalous-mon.cursor"

echo "anomalous-mon uninstalled."
