#!/usr/bin/env bash
# uninstall.sh — Remove anomalous-mon systemd user timer and service
set -euo pipefail

SERVICE_DIR="${HOME}/.config/systemd/user"

systemctl --user disable --now anomalous-mon.timer 2>/dev/null || true
systemctl --user disable --now anomalous-mon-stale.timer 2>/dev/null || true
rm -f "$SERVICE_DIR/anomalous-mon.service" \
      "$SERVICE_DIR/anomalous-mon.timer" \
      "$SERVICE_DIR/anomalous-mon-stale.service" \
      "$SERVICE_DIR/anomalous-mon-stale.timer"
systemctl --user daemon-reload

# Clean up runtime state (anomalous-mon files only, regenerable)
STATE_DIR="${XDG_RUNTIME_DIR:-/tmp}"
rm -f "${STATE_DIR}/anomalous-mon."*

# NOTE: deliberately preserve ${XDG_STATE_HOME:-$HOME/.local/state}/anomalous-mon/
# — the stale-acks file is user-curated data, not ephemeral state.

echo "anomalous-mon uninstalled."
echo "(stale-acks preserved at ${XDG_STATE_HOME:-$HOME/.local/state}/anomalous-mon/)"
