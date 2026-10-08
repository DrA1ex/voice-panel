#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
PLIST="$ROOT_DIR/Resources/Info.plist"

python3 - "$PLIST" <<'PY'
import plistlib
import re
import sys
from pathlib import Path

plist_path = Path(sys.argv[1])
with plist_path.open("rb") as handle:
    info = plistlib.load(handle)

errors: list[str] = []

bundle_id = str(info.get("CFBundleIdentifier", ""))
version = str(info.get("CFBundleShortVersionString", ""))
build = str(info.get("CFBundleVersion", ""))
minimum_system = str(info.get("LSMinimumSystemVersion", ""))
icon_file = str(info.get("CFBundleIconFile", ""))

if not re.fullmatch(r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+", bundle_id):
    errors.append("CFBundleIdentifier must be a reverse-DNS identifier")
if any(marker in bundle_id.lower() for marker in ("prototype", "example", "local")):
    errors.append("CFBundleIdentifier still contains a development placeholder")
if not re.fullmatch(r"\d+\.\d+\.\d+", version):
    errors.append("CFBundleShortVersionString must use release form MAJOR.MINOR.PATCH")
if "dev" in version.lower() or "beta" in version.lower():
    errors.append("CFBundleShortVersionString still identifies a development build")
if not re.fullmatch(r"[1-9]\d*", build):
    errors.append("CFBundleVersion must be a positive integer")
if minimum_system != "14.0":
    errors.append("LSMinimumSystemVersion must remain 14.0")
if icon_file != "VoicePanel.icns":
    errors.append("CFBundleIconFile must reference VoicePanel.icns")
elif not plist_path.with_name(icon_file).is_file():
    errors.append("VoicePanel.icns is missing from Resources")
if info.get("LSUIElement") is not True:
    errors.append("LSUIElement must remain enabled for the menu-bar application")
for key in ("NSMicrophoneUsageDescription", "NSSpeechRecognitionUsageDescription"):
    if not str(info.get(key, "")).strip():
        errors.append(f"{key} is missing")

if errors:
    for error in errors:
        print(f"Release metadata check failed: {error}", file=sys.stderr)
    raise SystemExit(1)

print(f"Release metadata is valid: VoicePanel {version} ({build}), {bundle_id}")
PY
