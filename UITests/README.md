# VoicePanel UI tests

VoicePanel uses XCTest with XCUIAutomation for end-to-end macOS interface regression tests.
The suite launches the real packaged `VoicePanel.app`, while a tiny host target provides the
Xcode UI-test runner required by XCUIAutomation.

Run the complete eight-scenario suite on macOS with the full Xcode installation selected:

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
./scripts/test-ui.sh
```

For the four highest-value recording, retry/cancel, import, and status-menu/persistence workflows:

```bash
./scripts/test-ui.sh --quick
```

Other useful modes:

```bash
./scripts/test-ui.sh --test testRecordingHappyPathProducesTranscriptActionsAndHistory
./scripts/test-ui.sh --clean
./scripts/test-ui.sh --bootstrap
```

Normal runs preserve `.build/ui-tests/DerivedData`, so `build-for-testing` remains incremental.
If an incremental build fails, the runner automatically removes only DerivedData and retries once.
Use `--clean` when a deliberately clean Xcode build is required. Disposable result bundles,
temporary encrypted history directories, and leftover test processes are still cleaned automatically.

The diagnostic XCTest bootstrap no longer runs before every successful suite. It is available through
`--bootstrap` and is launched automatically only when the suite log contains no XCTest activity at all.
Ordinary assertion failures are reported directly and never trigger a second diagnostic test process.

`VoicePanelUITestHarness.xcodeproj` is checked into the repository and is the source of truth for
the UI-test host and bundle. The runner does not generate a project at runtime and has no XcodeGen
or Homebrew dependency. Both targets use Xcode's automatic Info.plist generation and project-relative
source paths.

The test launch mode uses an isolated `UserDefaults` suite, opens Settings directly, avoids registering
the global hot key, does not preload a recognition model, and stores encrypted test history in a unique
temporary directory with a temporary local key. It never changes normal VoicePanel preferences or the
user's Keychain.

The complete suite is organized into eight user-level scenarios instead of many small tests. This
keeps the same assertions while reducing application launches and XCTest setup/teardown cycles:

- Settings pages, core controls, installed models, workflow, appearance, History, and Advanced;
- VAD A/B selection and the two-timeline comparison sheet;
- performance layout, saved setup restoration, scoring controls, and pipeline visualization;
- real `NSOpenPanel` presentation and automatic cancellation;
- recording success, clipboard, full transcript, close behavior, and History persistence;
- recognition failure, retry, cancellation, and recovery;
- deterministic audio import and History persistence;
- normal/Option status menus and representative settings persistence across relaunch.

Existence checks first query the current accessibility snapshot and wait only when an element is not yet
present. Fast polling is used for disappearance and state transitions. This avoids the roughly one-second
polling floor that XCTest otherwise adds to every already-visible control.

XCUIAutomation must synthesize real input and bring tested windows to the front, so it cannot be fully
non-blocking on the same active macOS desktop. For uninterrupted local work, run the suite in a separate
macOS user GUI session, a macOS virtual machine, or a remote/CI Mac. `--quick` minimizes the time during
which the active desktop is controlled.

Every test prints live `[VoicePanel UI]` progress markers into the stage log. The shell runner uses the
actual XCTest log as the source of truth for startup diagnosis, emits a heartbeat, stores complete stage
logs and result bundles, and enforces an external deadline. If the bootstrap never reaches `bootstrap
started`, check macOS Accessibility access for Xcode and Xcode Helper.

Add stable accessibility identifiers for every new critical workflow before adding its UI test.
