#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_DIR="$ROOT_DIR/.build/ui-tests"
PROJECT_PATH="$ROOT_DIR/UITests/VoicePanelUITestHarness.xcodeproj"
DERIVED_DATA_PATH="$PROJECT_DIR/DerivedData"
RESULT_BUNDLE_PATH="$PROJECT_DIR/VoicePanelUITests.xcresult"
BOOTSTRAP_RESULT_BUNDLE_PATH="$PROJECT_DIR/VoicePanelUITestBootstrap.xcresult"
PROGRESS_PATH="$PROJECT_DIR/VoicePanelUITests.progress.log"
DESTINATION="platform=macOS,arch=$(uname -m)"
HEARTBEAT_SECONDS="${VOICEPANEL_UI_TEST_HEARTBEAT_SECONDS:-10}"
BUILD_TIMEOUT_SECONDS="${VOICEPANEL_UI_TEST_BUILD_TIMEOUT_SECONDS:-240}"
BOOTSTRAP_TIMEOUT_SECONDS="${VOICEPANEL_UI_TEST_BOOTSTRAP_TIMEOUT_SECONDS:-90}"
SUITE_TIMEOUT_SECONDS="${VOICEPANEL_UI_TEST_SUITE_TIMEOUT_SECONDS:-420}"

RUN_MODE="full"
CLEAN_BUILD=0
RUN_BOOTSTRAP=0
TARGET_TEST=""

usage() {
    cat <<'USAGE'
Usage: scripts/test-ui.sh [options]

Options:
  --quick          Run the four highest-value user workflows.
  --full           Run the complete eight-scenario UI suite (default).
  --test NAME      Run one VoicePanelUITests test method.
  --clean          Remove UI-test DerivedData before building.
  --bootstrap      Run the diagnostic XCTest bootstrap before the suite.
  -h, --help       Show this help.

Normal runs preserve incremental DerivedData. If an incremental build fails,
the script automatically retries once with a clean DerivedData directory.
USAGE
}

while (( $# > 0 )); do
    case "$1" in
        --quick)
            RUN_MODE="quick"
            ;;
        --full)
            RUN_MODE="full"
            ;;
        --clean)
            CLEAN_BUILD=1
            ;;
        --bootstrap)
            RUN_BOOTSTRAP=1
            ;;
        --test)
            shift
            if (( $# == 0 )); then
                echo "--test requires a test method name." >&2
                exit 2
            fi
            TARGET_TEST="$1"
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
    shift
done

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "VoicePanel UI tests require macOS and Xcode." >&2
    exit 1
fi

if ! command -v xcodebuild >/dev/null 2>&1; then
    echo "xcodebuild was not found. Install Xcode and select it with xcode-select." >&2
    exit 1
fi

ACTIVE_DEVELOPER_DIR="$(xcode-select -p 2>/dev/null || true)"
if [[ -z "$ACTIVE_DEVELOPER_DIR" || "$ACTIVE_DEVELOPER_DIR" == *"/CommandLineTools" ]]; then
    echo "VoicePanel UI tests require the full Xcode developer directory." >&2
    echo "Select it with: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer" >&2
    exit 1
fi

cleanup_ui_test_history() {
    local temp_root="${TMPDIR:-/tmp}"
    [[ -d "$temp_root" ]] || return 0

    local history_path
    while IFS= read -r -d '' history_path; do
        chflags -R nouchg,noschg "$history_path" >/dev/null 2>&1 || true
        chmod -RN "$history_path" >/dev/null 2>&1 || true
        chmod -R u+rwX "$history_path" >/dev/null 2>&1 || true
        rm -rf "$history_path" >/dev/null 2>&1 || true
    done < <(find "$temp_root" -maxdepth 1 -type d -name 'VoicePanel-UITest-History-*' -print0 2>/dev/null)
}

cleanup_ui_processes() {
    pkill -x VoicePanel >/dev/null 2>&1 || true
    pkill -x VoicePanelUITestHost >/dev/null 2>&1 || true
    pkill -f 'VoicePanelUITests-Runner' >/dev/null 2>&1 || true

    if [[ -d "$PROJECT_DIR" ]]; then
        local pid
        while IFS= read -r pid; do
            [[ -n "$pid" && "$pid" != "$$" ]] || continue
            kill -TERM "$pid" >/dev/null 2>&1 || true
        done < <(pgrep -f "$PROJECT_DIR" 2>/dev/null || true)
    fi
}

remove_stale_ui_test_output() {
    local path="$1"
    [[ -e "$path" || -L "$path" ]] || return 0

    chflags -R nouchg,noschg "$path" >/dev/null 2>&1 || true
    chmod -RN "$path" >/dev/null 2>&1 || true
    chmod -R u+rwX "$path" >/dev/null 2>&1 || true
    rm -rf "$path" >/dev/null 2>&1 || true
    [[ ! -e "$path" && ! -L "$path" ]] && return 0

    cleanup_ui_processes
    sleep 0.2
    chflags -R nouchg,noschg "$path" >/dev/null 2>&1 || true
    chmod -RN "$path" >/dev/null 2>&1 || true
    chmod -R u+rwX "$path" >/dev/null 2>&1 || true
    rm -rf "$path" >/dev/null 2>&1 || true
    [[ ! -e "$path" && ! -L "$path" ]] && return 0

    local quarantine="${path}.stale.$(date +%Y%m%d%H%M%S).$$"
    if mv "$path" "$quarantine" >/dev/null 2>&1; then
        echo "Moved locked UI-test output aside: $quarantine" >&2
        rm -rf "$quarantine" >/dev/null 2>&1 || true
        return 0
    fi

    echo "Could not clear stale UI-test output: $path" >&2
    echo "Close any remaining xcodebuild/XCTest process and check file ownership under .build/ui-tests." >&2
    return 1
}

print_process_diagnostics() {
    local processes
    processes="$(pgrep -lf 'xcodebuild|xctest|VoicePanelUITest|VoicePanel' 2>/dev/null || true)"
    if [[ -n "$processes" ]]; then
        echo "Active UI-test worker processes:" >&2
        printf '%s\n' "$processes" >&2
    else
        echo "No leftover UI-test worker process was found." >&2
    fi
}

suite_log_shows_xctest_activity() {
    local log_path="$1"
    [[ -f "$log_path" ]] || return 1
    grep -qE '\[VoicePanel UI\]|Test Case .* (started|passed|failed)|Test Suite .* (started|passed|failed)|Executed [0-9]+ tests?' "$log_path"
}

terminate_stage_process() {
    local pid="$1"
    kill -TERM "$pid" >/dev/null 2>&1 || true
    sleep 0.5
    if kill -0 "$pid" >/dev/null 2>&1; then
        kill -KILL "$pid" >/dev/null 2>&1 || true
    fi
    cleanup_ui_processes
}

run_xcodebuild_stage() {
    local stage_name="$1"
    local timeout_seconds="$2"
    shift 2

    local log_path="$PROJECT_DIR/${stage_name}.log"
    : > "$log_path"

    echo
    echo "==> $stage_name"
    echo "Log: $log_path"

    xcodebuild "$@" >"$log_path" 2>&1 &
    local xcodebuild_pid=$!

    tail -n +1 -f "$log_path" &
    local tail_pid=$!

    local started_at=$SECONDS
    local next_heartbeat=$((started_at + HEARTBEAT_SECONDS))
    local last_progress_lines=0

    while kill -0 "$xcodebuild_pid" >/dev/null 2>&1; do
        sleep 0.25
        local elapsed=$((SECONDS - started_at))

        if [[ -f "$PROGRESS_PATH" ]]; then
            local progress_lines
            progress_lines=$(wc -l < "$PROGRESS_PATH" | tr -d ' ')
            if (( progress_lines > last_progress_lines )); then
                echo "--- XCTest progress ---"
                sed -n "$((last_progress_lines + 1)),${progress_lines}p" "$PROGRESS_PATH"
                echo "-----------------------"
                last_progress_lines="$progress_lines"
            fi
        fi

        if (( SECONDS >= next_heartbeat )); then
            echo "[$stage_name] still running after ${elapsed}s (xcodebuild PID $xcodebuild_pid)..." >&2
            next_heartbeat=$((SECONDS + HEARTBEAT_SECONDS))
        fi

        if (( elapsed >= timeout_seconds )); then
            echo "[$stage_name] timed out after ${timeout_seconds}s." >&2
            terminate_stage_process "$xcodebuild_pid"
            kill "$tail_pid" >/dev/null 2>&1 || true
            wait "$tail_pid" >/dev/null 2>&1 || true
            print_process_diagnostics
            if [[ -s "$PROGRESS_PATH" ]]; then
                echo "Last XCTest progress markers:" >&2
                tail -n 20 "$PROGRESS_PATH" >&2 || true
            else
                echo "No XCTest progress marker was written; the test bundle may not have started." >&2
            fi
            echo "Full log: $log_path" >&2
            return 124
        fi
    done

    local status=0
    wait "$xcodebuild_pid" || status=$?
    kill "$tail_pid" >/dev/null 2>&1 || true
    wait "$tail_pid" >/dev/null 2>&1 || true
    if (( status != 0 )); then
        echo "Compiler and test diagnostics:" >&2
        local diagnostic_lines
        diagnostic_lines="$(grep -nE '(^|[[:space:]])(error:|fatal error:)|SwiftCompile|Testing failed:|Failing tests:|Test Case .* failed|Executed [0-9]+ tests?|\*\* TEST|The following build commands failed:' "$log_path" \
            | tail -n 160 || true)"
        if [[ -n "$diagnostic_lines" ]]; then
            printf '%s\n' "$diagnostic_lines" >&2
        else
            echo "No concise compiler/XCTest diagnostic was found; last 40 log lines:" >&2
            tail -n 40 "$log_path" >&2 || true
        fi
        echo "[$stage_name] failed with exit code $status." >&2
        print_process_diagnostics
        echo "Full log: $log_path" >&2
        return "$status"
    fi
}

run_bootstrap_diagnostic() {
    remove_stale_ui_test_output "$BOOTSTRAP_RESULT_BUNDLE_PATH"
    : > "$PROGRESS_PATH"
    echo "Running the diagnostic XCTest bootstrap."
    run_xcodebuild_stage \
        "02-bootstrap-test" \
        "$BOOTSTRAP_TIMEOUT_SECONDS" \
        "${COMMON_XCODEBUILD_ARGS[@]}" \
        -resultBundlePath "$BOOTSTRAP_RESULT_BUNDLE_PATH" \
        "${TEST_TIMEOUT_ARGS[@]}" \
        -only-testing:VoicePanelUITests/VoicePanelUITestBootstrapTests/testHarnessStarts \
        test-without-building
}

cleanup_ui_processes
cleanup_ui_test_history
trap 'cleanup_ui_processes; cleanup_ui_test_history' EXIT

mkdir -p "$PROJECT_DIR"
# Normal runs preserve incremental DerivedData; only disposable result artifacts are cleared.
remove_stale_ui_test_output "$RESULT_BUNDLE_PATH"
remove_stale_ui_test_output "$BOOTSTRAP_RESULT_BUNDLE_PATH"
if (( CLEAN_BUILD )); then
    echo "Removing UI-test DerivedData because --clean was requested."
    remove_stale_ui_test_output "$DERIVED_DATA_PATH"
fi
: > "$PROGRESS_PATH"

CONFIGURATION=debug "$ROOT_DIR/scripts/build-app.sh" >/dev/null

if [[ ! -f "$PROJECT_PATH/project.pbxproj" ]]; then
    echo "The checked-in UI-test Xcode project is missing: $PROJECT_PATH" >&2
    exit 1
fi

COMMON_XCODEBUILD_ARGS=(
    -project "$PROJECT_PATH"
    -scheme VoicePanelUITests
    -destination "$DESTINATION"
    -derivedDataPath "$DERIVED_DATA_PATH"
    -parallel-testing-enabled NO
)

TEST_TIMEOUT_ARGS=(
    -test-timeouts-enabled YES
    -default-test-execution-time-allowance 60
    -maximum-test-execution-time-allowance 90
)

TEST_SELECTION_ARGS=(
    -skip-testing:VoicePanelUITests/VoicePanelUITestBootstrapTests
)

if [[ -n "$TARGET_TEST" ]]; then
    TARGET_TEST="${TARGET_TEST#VoicePanelUITests/VoicePanelUITests/}"
    TARGET_TEST="${TARGET_TEST#VoicePanelUITests.}"
    TEST_SELECTION_ARGS+=("-only-testing:VoicePanelUITests/VoicePanelUITests/$TARGET_TEST")
elif [[ "$RUN_MODE" == "quick" ]]; then
    QUICK_TESTS=(
        testRecordingHappyPathProducesTranscriptActionsAndHistory
        testRecordingFailureCanBeRetriedAndRecordingCanBeCancelled
        testAudioImportFixtureCompletesSuccessfully
        testStatusMenuAndRepresentativeSettingsPersistAcrossRelaunch
    )
    for test_name in "${QUICK_TESTS[@]}"; do
        TEST_SELECTION_ARGS+=("-only-testing:VoicePanelUITests/VoicePanelUITests/$test_name")
    done
fi

echo "Building UI-test products with incremental DerivedData."
build_status=0
run_xcodebuild_stage \
    "01-build-for-testing" \
    "$BUILD_TIMEOUT_SECONDS" \
    "${COMMON_XCODEBUILD_ARGS[@]}" \
    build-for-testing || build_status=$?

if (( build_status != 0 )); then
    echo "Incremental UI-test build failed; retrying once with clean DerivedData." >&2
    remove_stale_ui_test_output "$DERIVED_DATA_PATH"
    run_xcodebuild_stage \
        "01-build-for-testing-clean-retry" \
        "$BUILD_TIMEOUT_SECONDS" \
        "${COMMON_XCODEBUILD_ARGS[@]}" \
        build-for-testing
fi

if (( RUN_BOOTSTRAP )); then
    run_bootstrap_diagnostic
fi

SUITE_RESULT_ARGS=()
if [[ "$RUN_MODE" != "quick" || -n "$TARGET_TEST" ]]; then
    remove_stale_ui_test_output "$RESULT_BUNDLE_PATH"
    SUITE_RESULT_ARGS=(-resultBundlePath "$RESULT_BUNDLE_PATH")
fi
: > "$PROGRESS_PATH"
echo "Running ${RUN_MODE} UI suite. XCUIAutomation will control the active macOS desktop while it runs."
suite_status=0
run_xcodebuild_stage \
    "03-ui-test-suite" \
    "$SUITE_TIMEOUT_SECONDS" \
    "${COMMON_XCODEBUILD_ARGS[@]}" \
    "${SUITE_RESULT_ARGS[@]}" \
    "${TEST_TIMEOUT_ARGS[@]}" \
    "${TEST_SELECTION_ARGS[@]}" \
    test-without-building || suite_status=$?

if (( suite_status != 0 )); then
    SUITE_LOG_PATH="$PROJECT_DIR/03-ui-test-suite.log"
    if suite_log_shows_xctest_activity "$SUITE_LOG_PATH"; then
        echo "XCTest started normally and reported test/assertion failures; bootstrap diagnostic skipped." >&2
    elif [[ ! -s "$PROGRESS_PATH" && $RUN_BOOTSTRAP -eq 0 ]]; then
        echo >&2
        echo "The suite stopped before any XCTest activity was observed; running the bootstrap diagnostic." >&2
        run_bootstrap_diagnostic || true
        echo "If bootstrap also stops before 'bootstrap started', enable Xcode and Xcode Helper in" >&2
        echo "System Settings > Privacy & Security > Accessibility." >&2
        echo "Apple requires this permission for macOS XCUIAutomation." >&2
    fi
    exit "$suite_status"
fi

if (( ${#SUITE_RESULT_ARGS[@]} > 0 )); then
    echo "UI test result bundle: $RESULT_BUNDLE_PATH"
fi
