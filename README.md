# QuietBar

A small native macOS menu bar app that quits selected applications after you switch away. Swift, AppKit, and SwiftUI; no external dependencies, helper services, scripts, or permission prompts.

## Run locally

Requires macOS 13 or later and Xcode 15 or later to build.

1. Open `QuietBar.xcodeproj` in Xcode.
2. Select the **QuietBar** scheme and **My Mac**, then press **⌘R**. The project uses local ad hoc signing; no development team is needed.
3. Settings open on first launch. Afterward, click the moon icon in the menu bar → **Settings…**. Opening QuietBar again also opens Settings. There is no Dock icon.
4. Search for an app, select it, set its timeout, and enable **Automatically close when inactive**.

The locally built `QuietBar.app` beside this project can also be opened directly. It is an Apple Silicon build, locally signed for this machine, and has not been published, distributed, or notarised. To build for another Mac, use the Xcode project there.

From this directory, a command-line build is also available:

```sh
xcodebuild -project QuietBar.xcodeproj -scheme QuietBar \
  -configuration Release -derivedDataPath build build
open build/Build/Products/Release/QuietBar.app
```

For Launch at Login, quit the development copy, keep one copy of `QuietBar.app` in a stable location such as `~/Applications`, and open that copy. Choose **Settings → General → Launch at login**. If macOS requests approval, use **Open Login Items in System Settings** and approve QuietBar. Disable the toggle before moving or removing the app. Xcode builds can move or replace the registered app, so use a stable copy for login.

## Behavior

- Every application starts disabled. Defaults: 30 seconds, Normal quit, 5-second force fallback.
- Switching away starts the countdown, including when windows remain open. Returning cancels it; switching away again starts the full timeout.
- Enabling an inactive app, changing its settings, starting QuietBar, or resuming starts a fresh countdown for enabled inactive instances.
- **Normal quit** requests termination once. Applications may show save confirmations. If an app remains running after five seconds, QuietBar reports that it may be waiting for a response or refusing to quit. It retries only after you return and switch away, or explicitly change the policy.
- **Normal quit, then force quit** requests normal termination and force quits after the configured 1–300 second delay, provided that same process is still inactive and the policy still permits force quitting.
- **Force quit only** skips normal termination. Selecting either forced mode requires a per-app confirmation.
- Timeouts support seconds or minutes, from 1 second to 24 hours. Policy changes restart the full countdown.
- Pause cancels countdowns and pending fallbacks. Resume starts fresh timers. Sleep and inactive login sessions also cancel timers; wake/session restoration starts fresh timers. Manual pause persists across restarts.
- The menu shows pending requests. Settings show process IDs, countdowns, status, and the last 200 activity events from the current session.

**Force quitting may discard unsaved work, including while a save confirmation is open. Unsaved documents cannot be reliably detected across all applications.** Returning to an app cancels a pending fallback, but a normal quit request already sent cannot be recalled. A force request already delivered to macOS cannot be recalled either.

## Storage and discovery

Policies are saved atomically in `~/Library/Application Support/QuietBar/settings.json`, keyed by bundle identifier so updates and relaunches retain settings. Newly discovered apps remain disabled. Multiple copies sharing a bundle identifier share a policy; each running process has its own timer.

The catalog scans `/Applications`, `~/Applications`, `/System/Applications`, Safari's system app directory, and bundles of running applications. It includes apps nested in standard application folders. Directory change events and workspace launch/mount notifications trigger debounced refreshes; **Refresh** is also available. Apps stored elsewhere appear when launched. Unavailable apps retain their saved rules.

QuietBar protects its own bundle and PID, Finder, Dock, loginwindow, SystemUIServer, and other essential macOS components. Only regular foreground-capable applications with a bundle identifier and launch date are eligible; background agents, system components, and unidentified processes are excluded.

Settings read failures leave everything disabled and paused without overwriting the original file. General offers a backup-and-reset action for unreadable settings. Write failures are displayed and logged; changes that cannot be saved are rejected, except that pausing remains effective for safety.

## Source layout

| File | Responsibility |
| --- | --- |
| `QuietBarApp.swift` | AppKit lifecycle, menu bar, popover, settings window, single-instance startup |
| `InactivityMonitor.swift` | Workspace notifications, process identities, one-shot timers, quit requests and bounded history |
| `ApplicationCatalog.swift` | Background discovery and directory watchers |
| `SettingsStore.swift` | Validated local policies and atomic persistence |
| `LoginItemManager.swift` | `SMAppService.mainApp` registration and actual status |
| `Models.swift`, `Views.swift` | Safety rules, status models and native SwiftUI interface |

Termination is serialized on the main actor. Each timer carries a generation token and PID/launch-date identity. Before every normal or forced request, the monitor resolves the running process again and checks its identity, safety exclusions, activation, pause state, and policy. KVO supplements workspace termination notifications. Only one one-shot timer per process is retained. UI countdowns update only while their window/popover is present; history is bounded and kept in memory. Icons use a bounded cache. No accessibility or automation permissions are requested. App Sandbox is off because macOS does not permit cross-application force termination from sandboxed apps.

Diagnostic messages use Unified Logging with subsystem `local.QuietBar`, categories `Monitor`, `Settings`, and `Catalog`. Console can filter for this subsystem.

## Verification and changes

See [VERIFICATION.md](VERIFICATION.md) for observed results, environment limitations, and a short manual behavior check. This project deliberately has no automated test target or testing dependency. Behavior was exercised with disposable native AppKit applications using the production monitor and store.

When changing termination behavior, repeat the controlled foreground/timeout checks in the verification document using disposable applications, never applications containing user documents.

Apple references: [workspace activation](https://developer.apple.com/documentation/appkit/nsworkspace/didactivateapplicationnotification), [normal quit](https://developer.apple.com/documentation/appkit/nsrunningapplication/terminate()), [force termination](https://developer.apple.com/documentation/appkit/nsrunningapplication/forceterminate()), and [launch-at-login registration](https://developer.apple.com/documentation/servicemanagement/smappservice/register()).
