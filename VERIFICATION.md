# Verification record

Performed locally on 14 October 2026 using Xcode 27.0, macOS 27.0.1, and the installed macOS SDK. No publishing, notarisation, login helpers, or user application termination was performed.

## Build

- Debug and Release builds completed successfully with `xcodebuild`.
- The locally signed application bundle passed `codesign --verify --strict`.
- A subsequent standalone Release build compiled both `arm64` and `x86_64` into a universal binary. Intel execution remains untested.
- `QuietBar.dmg` passed its checksum verification, mounted read-only, and contained the signed universal app and a shortcut to `/Applications`. The mounted app passed signature verification for both architectures; its linked libraries are all macOS system libraries. The disk image was then ejected.
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

## UI correction in 1.0.1

The settings accessibility tree exposed the searchable list, icons, protected/disabled rows, per-app timeout, termination selection, safety text, activity/general sections, pause/resume, and login status. Searching for an installed application filtered the list. The pause control changed the displayed state.

The original 1.0 build exhausted its 256-descriptor limit by opening 253 application-folder directory watchers. CoreUI logged `Too many open files` when attempting to read appearance resources; this caused missing SwiftUI text, inspection timeouts, and settings write failures. The earlier attribution to missing host resources was incorrect: this was an application resource-management bug.

Version 1.0.1 replaces per-directory watchers with one recursive FSEvents stream, with retained callback context, weak ownership, and explicit stream cleanup. The corrected installed app used 23 descriptors during inspection. Application names, status captions, headings, safety text, and General settings were visibly verified in screenshots on this same Mac. No forced appearance or text-color workaround was added.

Through the actual utility UI, a disabled app's timeout was changed from 30 to 60 seconds and global pause enabled. The saved JSON was checked, QuietBar was quit with ⌘Q and reopened, and both values were verified in its UI. The timeout and pause were then restored to their original values; no application was enabled. Selecting a forced mode displayed the explicit unsaved-work confirmation; Cancel left Normal quit selected.

A targeted regression probe added 400 nested application-folder subdirectories and refreshed eight times. Descriptor count stayed at 23. Installing a disposable app inside a nested test folder triggered automatic discovery, left its policy disabled, and removal updated the catalog. Temporary folders were removed. See [catalog-stress-results.txt](verification/catalog-stress-results.txt).

## AppSweep branding and Preview recovery (1.1.1)

The app, project, installer, window titles, and UI are now named AppSweep, with a stack-clearing icon and copy about Dock clutter and idle application memory. The bundle identifier `local.QuietBar` and original settings folder are retained. Before/after settings files matched during the rename; the user subsequently authorized changing Preview to Normal quit followed by force quit after five seconds. That rule was selected through the installed app's explicit warning confirmation, with its existing 30-second inactivity timeout preserved.

Preview was reproduced as a live process (PID 47029) while both workspace lookup and lookup by that PID returned a stale `NSRunningApplication` with PID `-1` and an obsolete launch date. The production monitor now obtains PID/start-time identity and exact executable using public `libproc` APIs. Normal quit still uses AppKit. Explicit forced modes can use the public POSIX signal API if AppKit cannot address the verified live process. The signal boundary rechecks identity and executable and rejects the utility's own PID; the monitor also rechecks activation, pause, exclusions, and current policy.

After installing the corrected build, Activity showed the stale Preview process being recovered, its full 30-second countdown, a normal quit request, and exit. A fresh Preview launch (PID 51179) was then checked through the installed app: switching away displayed the countdown, Activity recorded normal quit and exit, and the five-second fallback rule remained enabled. These Preview instances exited normally; no force signal was needed in either observed Preview run. The stale-record signal branch is separately checked with a disposable refusing fixture, rather than claimed as exercised against Preview.

The 42 controlled monitor checks were repeated successfully, including active-app protection, fallback cancellation, refusal, force-only, multiple instances, pause/resume, and self-protection. The short force-only verification wait was adjusted to wait up to eight seconds for observed process exit on this busy host; no production timing was changed for the test. See [appsweep-behavior-results.txt](verification/appsweep-behavior-results.txt).

The updated Quit strength control displays all modes directly, and Activity warning rows offer a policy-review link. The installed UI was used to select and confirm Preview's fallback rule. Repeated automated document detection is not implemented or claimed.

A separate disposable refusing AppKit fixture exercised the direct signal boundary: mismatched start time and executable were rejected, the utility's own PID was protected, and the exact verified fixture exited after the signal. See [signal-results.txt](verification/signal-results.txt).

## Remaining verification limits

Launch-at-login registration uses the actual `SMAppService` status; inspected copies reported `.notFound`, which the UI explains. Registration and a real logout/login cycle were not performed. Real document save dialogs, locked screens, arbitrary third-party refusal behavior, and Intel execution were not tested. PID reuse protection was inspected in code; the OS was not forced to reuse a PID.

## Short manual check on your Mac

1. Run QuietBar, open Settings, and confirm all applications are disabled.
2. Use a disposable app/document. Enable a 10-second Normal quit timeout. Switch away with a window open: its countdown should appear. Return before expiry: it should cancel. Switch away again: it should restart at 10 seconds.
3. Let the timer expire. Check the app exits normally or displays its own save confirmation. QuietBar should report a still-running app if it has not exited after five seconds.
4. With disposable data only, choose the fallback mode, read and accept the per-app warning, and set a 5-second fallback. A refusing app should close only after the fallback expires. Returning during the fallback must cancel it.
5. Pause while a timer is running. Wait beyond its timeout: it should stay open. Resume: the full countdown should restart.
6. Set a distinctive timeout and pause state, quit QuietBar from the menu, and reopen it. Both settings should remain. Restore your preferred settings afterward.
7. Check QuietBar and Finder are protected. Close Settings and confirm the moon remains in the menu bar, with no Dock icon. Use the menu's **Quit QuietBar** to exit.
8. For login, use a stable app copy, enable **General → Launch at login**, approve it in System Settings if needed, and confirm it launches at the next login. Disable it to remove the registration.
