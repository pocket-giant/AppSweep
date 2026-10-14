# Verification record

Performed locally on 14 October 2026 using Xcode 27.0, macOS 27.0.1, and the installed macOS SDK. No publishing, notarisation, login helpers, or user application termination was performed.

## Build

- Debug and Release builds completed successfully with `xcodebuild`.
- The locally signed application bundle passed `codesign --verify --strict`.
- `LSUIElement` is true, the deployment target is macOS 13, and App Sandbox is disabled.
- Xcode emits an informational App Intents metadata extraction warning because this app does not use App Intents. There are no Swift compiler errors.

## Observed behavior

A small, temporary AppKit runner compiled the production `Models`, `SettingsStore`, and `InactivityMonitor` sources directly. It used real `NSWorkspace` launch/activation/termination events and `NSRunningApplication` requests against disposable, locally built native apps. Each fixture displayed a visible window. Refusal fixtures returned `.terminateCancel` from `applicationShouldTerminate`. They contained no user documents. The runner passed 42 assertions, including setup assertions; the retained log is [behavior-results.txt](verification/behavior-results.txt).

| Check | Observed result |
| --- | --- |
| Disabled-by-default policies and 30s / normal / 5s defaults | Passed |
| Switching away starts a countdown with an open visible window | Passed |
| Returning cancels the countdown and protects the active process beyond the old deadline | Passed |
| Switching away again restarts the full timeout | Passed |
| Normal quit causes the fixture's normal termination callback and exit | Passed |
| Terminated processes and their timers are removed | Passed |
| Refusing normal quit enters an explicitly enabled fallback | Passed |
| Returning during fallback cancels it; the active fixture survives past the fallback delay | Passed |
| Normal-only mode reports a still-running/refusing fixture without force quitting | Passed |
| Explicitly enabled force fallback closes a refusing fixture | Passed |
| Force-only mode closes a fixture without a normal-quit callback | Passed |
| Pause cancels timers; resume starts fresh timers | Passed |
| Distinct simultaneous instances have independent process states | Passed |
| Relaunched instances get a new identity without stale timers | Passed |
| Self-targeting force policy creates no timer or termination attempt for the utility process | Passed in the production monitor runner |
| Essential process exclusions | Finder, Dock, loginwindow and SystemUIServer checked |
| Sleep/wake handling | Passed with injected workspace notifications; actual sleep/wake not exercised |

Persistence was also checked across two separately launched AppKit processes using the production store: one saved an enabled 120-second fallback policy, a 7-second fallback delay, and global pause; the next restored all values. See [persistence-results.txt](verification/persistence-results.txt). No destructive policy was applied to a user application.

Application discovery was checked by temporarily installing an unused disposable bundle in `~/Applications`, observing the catalog refresh, confirming its disabled default, and removing it. See [catalog-results.txt](verification/catalog-results.txt).

## UI and environment limits

The settings accessibility tree exposed the searchable list, icons, protected/disabled rows, per-app timeout, termination selection, safety text, activity/general sections, pause/resume, and login status. Searching for an installed application filtered the list. The pause control changed the displayed state.

Full visual and UI persistence verification was limited by this host. Native inspection repeatedly timed out, and its macOS CoreUI logs reported missing system appearance resources (`DarkAqua.car`, `Graphite.car`, and vibrant variants). Some SwiftUI text was absent in captured images. UI edits also produced `NSCocoaErrorDomain` write errors (512), while direct production-store checks successfully wrote and restored settings. These failures are not counted as passing UI checks; a complete visual check and settings edit/restart check through the delivered utility UI remain to be performed on a normal macOS installation.

Launch-at-login registration uses the actual `SMAppService` status; a development copy reported `.notFound`, which the UI explains. Registration and a real logout/login cycle were not performed. Real document save dialogs, locked screens, arbitrary third-party refusal behavior, and Intel execution were not tested. PID reuse protection was inspected in code; the OS was not forced to reuse a PID.

## Short manual check on your Mac

1. Run QuietBar, open Settings, and confirm all applications are disabled.
2. Use a disposable app/document. Enable a 10-second Normal quit timeout. Switch away with a window open: its countdown should appear. Return before expiry: it should cancel. Switch away again: it should restart at 10 seconds.
3. Let the timer expire. Check the app exits normally or displays its own save confirmation. QuietBar should report a still-running app if it has not exited after five seconds.
4. With disposable data only, choose the fallback mode, read and accept the per-app warning, and set a 5-second fallback. A refusing app should close only after the fallback expires. Returning during the fallback must cancel it.
5. Pause while a timer is running. Wait beyond its timeout: it should stay open. Resume: the full countdown should restart.
6. Set a distinctive timeout and pause state, quit QuietBar from the menu, and reopen it. Both settings should remain. Restore your preferred settings afterward.
7. Check QuietBar and Finder are protected. Close Settings and confirm the moon remains in the menu bar, with no Dock icon. Use the menu's **Quit QuietBar** to exit.
8. For login, use a stable app copy, enable **General → Launch at login**, approve it in System Settings if needed, and confirm it launches at the next login. Disable it to remove the registration.
