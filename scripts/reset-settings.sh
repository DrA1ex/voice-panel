#!/usr/bin/env bash
set -euo pipefail

DOMAINS=("io.github.dra1ex.VoicePanel" "dev.voicepanel.prototype")
SUPPORT_DIR="$HOME/Library/Application Support/VoicePanel"

if pgrep -x VoicePanel >/dev/null 2>&1; then
    echo "Quit VoicePanel before resetting settings." >&2
    exit 1
fi

# UserDefaults preferences only. Downloaded models and history remain intact.
for domain in "${DOMAINS[@]}"; do
    defaults delete "$domain" >/dev/null 2>&1 || true
done
rm -f \
    "$SUPPORT_DIR/Diagnostics/running-session.json" \
    "$SUPPORT_DIR/Diagnostics/model-load.json"

echo "VoicePanel settings and recovery markers were reset."
echo "Downloaded models and transcript history were preserved."
