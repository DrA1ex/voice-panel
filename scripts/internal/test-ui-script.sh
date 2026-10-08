#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

HARNESS_ROOT="$TMP_DIR/harness"
FAKE_BIN="$TMP_DIR/bin"
LOG_DIR="$TMP_DIR/logs"
mkdir -p "$HARNESS_ROOT/scripts" "$HARNESS_ROOT/UITests" "$FAKE_BIN" "$LOG_DIR"
cp "$ROOT_DIR/scripts/test-ui.sh" "$HARNESS_ROOT/scripts/test-ui.sh"
cp -R "$ROOT_DIR/UITests/VoicePanelUITestHarness.xcodeproj" "$HARNESS_ROOT/UITests/VoicePanelUITestHarness.xcodeproj"
chmod +x "$HARNESS_ROOT/scripts/test-ui.sh"

cat > "$HARNESS_ROOT/scripts/build-app.sh" <<'FAKE_BUILD'
#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$ROOT_DIR/.build/app/VoicePanel.app"
printf '%s\n' "$ROOT_DIR/.build/app/VoicePanel.app"
FAKE_BUILD
chmod +x "$HARNESS_ROOT/scripts/build-app.sh"

cat > "$FAKE_BIN/uname" <<'FAKE_UNAME'
#!/usr/bin/env bash
case "${1:-}" in
    -s) printf 'Darwin\n' ;;
    -m) printf 'arm64\n' ;;
    *) printf 'Darwin\n' ;;
esac
FAKE_UNAME

cat > "$FAKE_BIN/xcode-select" <<'FAKE_XCODE_SELECT'
#!/usr/bin/env bash
if [[ "${1:-}" == "-p" ]]; then
    printf '/Applications/Xcode.app/Contents/Developer\n'
    exit 0
fi
exit 1
FAKE_XCODE_SELECT

cat > "$FAKE_BIN/xcodebuild" <<FAKE_XCODEBUILD
#!/usr/bin/env bash
set -euo pipefail
count_file="$LOG_DIR/xcodebuild.count"
count=0
if [[ -f "\$count_file" ]]; then
    count=\$(cat "\$count_file")
fi
count=\$((count + 1))
printf '%s\n' "\$count" > "\$count_file"
printf '%s\n' "\$@" > "$LOG_DIR/xcodebuild.\${count}.args"

if [[ "\${VOICEPANEL_FAKE_XCODEBUILD_SUITE_FAILURE:-0}" == "1" ]] \
    && printf '%s\n' "\$@" | grep -q 'test-without-building' \
    && printf '%s\n' "\$@" | grep -q -- '-skip-testing:VoicePanelUITests/VoicePanelUITestBootstrapTests'; then
    echo "Test Suite 'Selected tests' started"
    echo "[VoicePanel UI] fake test setUp started"
    echo "Test Case '-[VoicePanelUITests fakeTest]' failed"
    echo "Executed 1 test, with 1 failure"
    echo "** TEST EXECUTE FAILED **"
    exit 65
fi
FAKE_XCODEBUILD

chmod +x "$FAKE_BIN/uname" "$FAKE_BIN/xcode-select" "$FAKE_BIN/xcodebuild"

DERIVED_DATA_MARKER="$HARNESS_ROOT/.build/ui-tests/DerivedData/cache-marker"
mkdir -p "$(dirname "$DERIVED_DATA_MARKER")"
printf 'keep incremental cache\n' > "$DERIVED_DATA_MARKER"

STALE_RESULT="$HARNESS_ROOT/.build/ui-tests/VoicePanelUITests.xcresult"
mkdir -p "$STALE_RESULT"
printf 'stale\n' > "$STALE_RESULT/output"
chmod -R a-w "$STALE_RESULT"

UI_TEST_TEMP_ROOT="$TMP_DIR/ui-test-temp"
STALE_HISTORY_DIR="$UI_TEST_TEMP_ROOT/VoicePanel-UITest-History-stale"
mkdir -p "$STALE_HISTORY_DIR"
printf 'temporary key\n' > "$STALE_HISTORY_DIR/history.test-key"

run_harness() {
    TMPDIR="$UI_TEST_TEMP_ROOT" PATH="$FAKE_BIN:$PATH" \
        "$HARNESS_ROOT/scripts/test-ui.sh" "$@" >>"$LOG_DIR/stdout" 2>>"$LOG_DIR/stderr"
}

run_harness

if [[ ! -e "$DERIVED_DATA_MARKER" ]]; then
    echo "test-ui.sh discarded the incremental DerivedData cache during a normal run" >&2
    exit 1
fi
if [[ -e "$STALE_RESULT" ]]; then
    echo "test-ui.sh did not clear the stale result bundle" >&2
    exit 1
fi
if [[ -e "$STALE_HISTORY_DIR" ]]; then
    echo "test-ui.sh did not remove stale temporary history secrets" >&2
    exit 1
fi

PROJECT_PATH="$HARNESS_ROOT/UITests/VoicePanelUITestHarness.xcodeproj"

python3 - "$LOG_DIR" "$PROJECT_PATH" <<'PY'
from pathlib import Path
import sys

log_dir = Path(sys.argv[1])
project_path = sys.argv[2]

if not (Path(project_path) / 'project.pbxproj').is_file():
    raise SystemExit('The checked-in UI-test Xcode project is missing')

invocations = []
for index in range(1, 3):
    path = log_dir / f'xcodebuild.{index}.args'
    if not path.is_file():
        raise SystemExit(f'test-ui.sh did not execute xcodebuild stage {index}')
    invocations.append(path.read_text().splitlines())

build_args, suite_args = invocations

for args in invocations:
    project_index = args.index('-project')
    if args[project_index + 1] != project_path:
        raise SystemExit('xcodebuild received the wrong checked-in project')
    destination_index = args.index('-destination')
    if args[destination_index + 1] != 'platform=macOS,arch=arm64':
        raise SystemExit('xcodebuild received a non-deterministic destination')

if 'build-for-testing' not in build_args:
    raise SystemExit('The first xcodebuild stage must build for testing')
if 'test-without-building' not in suite_args:
    raise SystemExit('UI test execution must use test-without-building after a separate build')
if '-skip-testing:VoicePanelUITests/VoicePanelUITestBootstrapTests' not in suite_args:
    raise SystemExit('The normal suite must skip the optional bootstrap test')
if any('VoicePanelUITestBootstrapTests/testHarnessStarts' in arg for arg in suite_args):
    raise SystemExit('The diagnostic bootstrap must not run during the normal path')

required_timeout_arguments = {
    '-test-timeouts-enabled': 'YES',
    '-default-test-execution-time-allowance': '60',
    '-maximum-test-execution-time-allowance': '90',
}
for flag, expected in required_timeout_arguments.items():
    index = suite_args.index(flag)
    if suite_args[index + 1] != expected:
        raise SystemExit(f'{flag} expected {expected}, got {suite_args[index + 1]}')
PY

run_harness --quick

python3 - "$LOG_DIR" <<'PY'
from pathlib import Path
import sys

log_dir = Path(sys.argv[1])
quick_args = (log_dir / 'xcodebuild.4.args').read_text().splitlines()
required = {
    '-only-testing:VoicePanelUITests/VoicePanelUITests/testRecordingHappyPathProducesTranscriptActionsAndHistory',
    '-only-testing:VoicePanelUITests/VoicePanelUITests/testRecordingFailureCanBeRetriedAndRecordingCanBeCancelled',
    '-only-testing:VoicePanelUITests/VoicePanelUITests/testAudioImportFixtureCompletesSuccessfully',
    '-only-testing:VoicePanelUITests/VoicePanelUITests/testStatusMenuAndRepresentativeSettingsPersistAcrossRelaunch',
}
missing = sorted(required.difference(quick_args))
if missing:
    raise SystemExit(f'Quick UI suite is missing targeted scenarios: {missing}')
if any('testAudioFileChooserAutoDismissesAndRestoresSettings' in arg for arg in quick_args):
    raise SystemExit('Quick UI suite must exclude the slower system file-panel scenario')
if '-resultBundlePath' in quick_args:
    raise SystemExit('Quick UI suite must skip xcresult generation unless diagnostics are requested')
PY

printf 'clean me\n' > "$DERIVED_DATA_MARKER"
run_harness --clean --test testSettingsPagesAndCoreControls
if [[ -e "$DERIVED_DATA_MARKER" ]]; then
    echo "test-ui.sh --clean did not remove DerivedData" >&2
    exit 1
fi

python3 - "$LOG_DIR" <<'PY'
from pathlib import Path
import sys

log_dir = Path(sys.argv[1])
targeted_args = (log_dir / 'xcodebuild.6.args').read_text().splitlines()
expected = '-only-testing:VoicePanelUITests/VoicePanelUITests/testSettingsPagesAndCoreControls'
if expected not in targeted_args:
    raise SystemExit('The --test option did not target the requested UI test')
PY



# A normal XCTest assertion failure must not trigger the bootstrap diagnostic.
before_failure_count=$(cat "$LOG_DIR/xcodebuild.count")
if VOICEPANEL_FAKE_XCODEBUILD_SUITE_FAILURE=1 run_harness --test testRecordingHappyPathProducesTranscriptActionsAndHistory; then
    echo "test-ui.sh unexpectedly succeeded for the simulated XCTest assertion failure" >&2
    exit 1
fi
after_failure_count=$(cat "$LOG_DIR/xcodebuild.count")
if (( after_failure_count - before_failure_count != 2 )); then
    echo "test-ui.sh launched an unexpected bootstrap/build stage after a normal XCTest failure" >&2
    exit 1
fi
if ! grep -Fq 'XCTest started normally and reported test/assertion failures; bootstrap diagnostic skipped.' "$LOG_DIR/stderr"; then
    echo "test-ui.sh did not classify the simulated assertion failure as an ordinary XCTest failure" >&2
    exit 1
fi
if grep -Fq 'The suite stopped before any XCTest activity was observed' "$LOG_DIR/stderr"; then
    echo "test-ui.sh incorrectly treated a normal assertion failure as a harness startup failure" >&2
    exit 1
fi

echo "UI test script regression test passed."
