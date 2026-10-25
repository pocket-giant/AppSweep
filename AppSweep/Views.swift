import AppKit
import SwiftUI

@MainActor
private enum AppIcons {
    static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 128
        return cache
    }()
    static func image(_ url: URL?) -> NSImage {
        guard let url else { return NSImage(systemSymbolName: "app", accessibilityDescription: nil)! }
        let key = url.path as NSString
        if let icon = cache.object(forKey: key) { return icon }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        cache.setObject(icon, forKey: key)
        return icon
    }
}

struct AppIcon: View {
    let url: URL?
    var size: CGFloat = 32
    var body: some View {
        Image(nsImage: AppIcons.image(url)).resizable().interpolation(.high)
            .frame(width: size, height: size).accessibilityHidden(true)
    }
}

struct StatusBadge: View {
    let status: ProcessStatus
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label).font(.caption).monospacedDigit().lineLimit(1)
        }.foregroundStyle(color)
    }
    private var color: Color {
        switch status.phase {
        case .active: return .green
        case .countdown: return .accentColor
        case .quitting, .forcing, .refused: return .orange
        case .idle: return .secondary
        }
    }
    private var label: String {
        switch status.phase {
        case .countdown: return "Quits in \(status.remainingSeconds)s"
        case .quitting where status.deadline != nil: return "Force fallback in \(status.remainingSeconds)s"
        case .refused: return "Still running · needs attention"
        default: return status.phase.title
        }
    }
}

struct MenuView: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var monitor: InactivityMonitor
    let openSettings: () -> Void
    let quit: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "square.stack.3d.up.slash.fill").font(.title2).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 3) {
                    Text("AppSweep").font(.headline)
                    Text(monitor.isPaused ? "Automatic closing paused" : "Less Dock clutter. Fewer idle apps.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            Button {
                store.setPaused(!store.paused)
            } label: {
                Label(store.paused ? "Resume automatic closing" : "Pause automatic closing",
                      systemImage: store.paused ? "play.fill" : "pause.fill").frame(maxWidth: .infinity)
            }.controlSize(.large)
            if let error = store.error { Text(error).font(.caption).foregroundStyle(.orange) }
            Divider()
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                let pending = monitor.orderedStatuses.filter { [.countdown, .quitting, .forcing, .refused].contains($0.phase) }
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("CURRENT ACTIVITY").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Spacer()
                        Text("\(pending.count)").font(.caption).foregroundStyle(.secondary)
                    }
                    if pending.isEmpty {
                        Text(store.policies.values.contains(where: \.enabled)
                             ? "No applications are waiting to close."
                             : "Choose applications in Settings to get started.")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(Array(pending.prefix(5))) { status in
                        HStack {
                            Text(status.name).lineLimit(1)
                            Spacer()
                            StatusBadge(status: status)
                        }.help("PID \(status.id.pid). \(status.detail ?? status.phase.title)")
                    }
                    if pending.count > 5 { Text("\(pending.count - 5) more in Settings").font(.caption).foregroundStyle(.secondary) }
                }
            }
            Divider()
            HStack {
                Button("Settings…", action: openSettings).keyboardShortcut(",")
                Spacer()
                Button("Quit AppSweep", action: quit).keyboardShortcut("q")
            }
        }.padding(20).frame(width: 350)
    }
}

private enum SettingsSection: String, CaseIterable, Identifiable {
    case applications = "Applications", activity = "Activity", general = "General"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .applications: return "square.grid.2x2"
        case .activity: return "clock.arrow.circlepath"
        case .general: return "gearshape"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var catalog: ApplicationCatalog
    @ObservedObject var monitor: InactivityMonitor
    @ObservedObject var login: LoginItemManager
    @State private var section: SettingsSection? = .applications
    @State private var selectedApp: String?
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                Label("AppSweep", systemImage: "square.stack.3d.up.slash.fill").font(.title3.weight(.semibold)).padding(.horizontal, 16).padding(.top, 20)
                List(SettingsSection.allCases, selection: $section) { item in
                    Label(item.rawValue, systemImage: item.symbol).tag(item).padding(.vertical, 5)
                }.listStyle(.sidebar)
                VStack(alignment: .leading, spacing: 8) {
                    Label(monitor.isPaused ? "Paused" : "Automatic closing on", systemImage: monitor.isPaused ? "pause.circle" : "checkmark.circle")
                        .font(.caption).foregroundStyle(monitor.isPaused ? Color.orange : Color.secondary)
                    Button(store.paused ? "Resume" : "Pause") { store.setPaused(!store.paused) }
                        .frame(maxWidth: .infinity)
                }.padding(16)
            }.frame(width: 180).background(.regularMaterial)
            Divider()
            VStack(spacing: 0) {
                if let error = store.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.orange)
                        .padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Color.orange.opacity(0.08))
                    Divider()
                }
                switch section ?? .applications {
                case .applications: ApplicationsView(store: store, catalog: catalog, monitor: monitor, selected: $selectedApp)
                case .activity: ActivityView(monitor: monitor) { bundleID in
                    selectedApp = bundleID
                    section = .applications
                }
                case .general: GeneralView(store: store, login: login)
                }
            }
        }.frame(minWidth: 940, minHeight: 620)
    }
}

private struct ApplicationsView: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var catalog: ApplicationCatalog
    @ObservedObject var monitor: InactivityMonitor
    @State private var search = ""
    @State private var enabledOnly = false
    @Binding var selected: String?
    private var allApps: [InstalledApp] {
        let present = Set(catalog.apps.map(\.id))
        let missing = store.policies.keys.filter { !present.contains($0) }.sorted().map {
            InstalledApp(id: $0, name: $0, url: nil, protection: "Application currently unavailable; saved settings are preserved")
        }
        return catalog.apps + missing
    }
    private var filtered: [InstalledApp] {
        allApps.filter {
            (!enabledOnly || store.policy(for: $0.id).enabled)
            && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.id.localizedCaseInsensitiveContains(search))
        }
    }
    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Applications").font(.title2.weight(.semibold))
                        Spacer()
                        Button { catalog.refresh() } label: { Image(systemName: "arrow.clockwise") }
                            .buttonStyle(.borderless).help("Refresh installed applications").disabled(catalog.scanning)
                    }
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Search applications", text: $search).textFieldStyle(.plain)
                            .accessibilityLabel("Search applications")
                        if !search.isEmpty {
                            Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Clear search")
                        }
                    }.padding(8).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
                    Toggle("Enabled only", isOn: $enabledOnly).toggleStyle(.checkbox).font(.caption)
                }.padding(18)
                Divider()
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    List(filtered, selection: $selected) { app in
                        HStack(spacing: 10) {
                            AppIcon(url: app.url)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(app.name).font(.body.weight(.medium)).lineLimit(1)
                                if app.protection != nil {
                                    Label("Protected / unavailable", systemImage: "lock.fill").font(.caption).foregroundStyle(.secondary)
                                } else if let status = monitor.orderedStatuses.first(where: { $0.bundleID == app.id }) {
                                    StatusBadge(status: status)
                                } else {
                                    Text("Not running").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 4)
                            Toggle("Auto-close \(app.name)", isOn: Binding(
                                get: { store.policy(for: app.id).enabled },
                                set: { var policy = store.policy(for: app.id); policy.enabled = $0; store.update(policy, for: app.id) }
                            )).labelsHidden().toggleStyle(.switch).controlSize(.small).disabled(app.protection != nil)
                        }.padding(.vertical, 5).tag(app.id)
                    }.listStyle(.inset)
                    .overlay {
                        if filtered.isEmpty {
                            VStack(spacing: 8) {
                                Image(systemName: "magnifyingglass").font(.largeTitle).foregroundStyle(.tertiary)
                                Text(catalog.scanning ? "Discovering applications…" : "No matching applications").foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Divider()
                Text("\(filtered.count) applications · \(store.policies.values.filter(\.enabled).count) enabled")
                    .font(.caption).foregroundStyle(.secondary).padding(12).frame(maxWidth: .infinity, alignment: .leading)
            }.frame(width: 330)
            Divider()
            if let app = allApps.first(where: { $0.id == selected }) {
                AppDetailView(app: app, store: store, monitor: monitor).id(app.id)
            } else {
                VStack(spacing: 14) {
                    Image(systemName: "timer").font(.system(size: 44, weight: .light)).foregroundStyle(Color.accentColor)
                    Text("Clear the app clutter").font(.title2.weight(.medium))
                    Text("Quit apps you’re done with to free memory\nand clear inactive, unpinned apps from your Dock.")
                        .multilineTextAlignment(.center).foregroundStyle(.secondary)
                    Text("Select an app and enable automatic closing.\nYou choose how long it stays open after switching away.")
                        .font(.callout).multilineTextAlignment(.center).foregroundStyle(.secondary)
                    Text("Finder, macOS services, and AppSweep are protected.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(28).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

private struct AppDetailView: View {
    let app: InstalledApp
    @ObservedObject var store: SettingsStore
    @ObservedObject var monitor: InactivityMonitor
    @State private var minutes = false
    @State private var proposedMode: TerminationMode?
    private var policy: AppPolicy { store.policy(for: app.id) }
    private func edit(_ change: (inout AppPolicy) -> Void) { var value = policy; change(&value); store.update(value, for: app.id) }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 14) {
                    AppIcon(url: app.url, size: 56)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(app.name).font(.title2.weight(.semibold)).textSelection(.enabled)
                        Text(app.id).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
                if let reason = app.protection {
                    Label(reason, systemImage: "lock.shield").foregroundStyle(.secondary)
                }
                GroupBox {
                    VStack(alignment: .leading, spacing: 16) {
                        Toggle("Automatically close when inactive", isOn: Binding(get: { policy.enabled }, set: { enabled in edit { $0.enabled = enabled } }))
                            .toggleStyle(.switch)
                        Divider()
                        Text("Inactivity timeout").font(.headline)
                        HStack {
                            TextField("Timeout", value: Binding(get: { policy.timeout / (minutes ? 60 : 1) },
                                set: { number in edit { $0.timeout = number * (minutes ? 60 : 1) } }), format: .number)
                                .textFieldStyle(.roundedBorder).frame(width: 85).accessibilityLabel("Inactivity timeout")
                            Picker("Unit", selection: $minutes) {
                                Text("Seconds").tag(false)
                                Text("Minutes").tag(true)
                            }.labelsHidden().frame(width: 110).accessibilityLabel("Timeout unit")
                        }
                        Text("1 second to 24 hours. Switching away starts the full countdown, including when windows are open. Returning cancels it.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(10)
                }.disabled(app.protection != nil)
                GroupBox {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Quit strength").font(.headline)
                        Picker("Termination mode", selection: Binding(get: { policy.mode }, set: { mode in
                            if mode == .normal { edit { $0.mode = mode } }
                            else if mode != policy.mode { proposedMode = mode }
                        })) {
                            ForEach(TerminationMode.allCases) { Text($0.title).tag($0) }
                        }.pickerStyle(.radioGroup).labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
                        if policy.mode == .normalThenForce {
                            HStack {
                                Text("Force fallback after")
                                TextField("Delay", value: Binding(get: { policy.fallbackDelay }, set: { delay in edit { $0.fallbackDelay = delay } }), format: .number)
                                    .textFieldStyle(.roundedBorder).frame(width: 60).accessibilityLabel("Force quit fallback delay")
                                Text("seconds").foregroundStyle(.secondary)
                            }
                            Text("1–300 seconds after requesting normal quit.").font(.caption).foregroundStyle(.secondary)
                        }
                        if policy.mode == .normal {
                            Text("Normal quit lets the application show save confirmations. If it stays open, AppSweep reports that and waits until you return and switch away again.")
                                .font(.caption).foregroundStyle(.secondary)
                            Text("For stubborn apps, choose Normal quit, then force quit. Force quit only skips the normal request entirely.")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Label("Force quitting may discard unsaved work, including while a save confirmation is open.", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption).foregroundStyle(.orange)
                        }
                        Text("Unsaved documents cannot be reliably detected across all applications.").font(.caption).foregroundStyle(.secondary)
                    }.padding(10)
                }.disabled(app.protection != nil)
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    let statuses = monitor.orderedStatuses.filter { $0.bundleID == app.id }
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Running instances").font(.headline)
                        if statuses.isEmpty { Text("Not running, or protected by macOS process safety rules.").font(.callout).foregroundStyle(.secondary) }
                        ForEach(statuses) { status in
                            VStack(alignment: .leading, spacing: 5) {
                                HStack { Text("PID \(status.id.pid)").font(.caption.monospaced()); Spacer(); StatusBadge(status: status) }
                                if let detail = status.detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
                            }.padding(10).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
                        }
                    }
                }
                Text("Changing a setting, enabling an inactive app, or resuming starts a fresh countdown. Sleep and session changes cancel pending requests.")
                    .font(.caption).foregroundStyle(.secondary)
                if let url = app.url {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }.font(.caption)
                }
            }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
        }
        .alert("Enable force quitting for \(app.name)?", isPresented: Binding(get: { proposedMode != nil }, set: { if !$0 { proposedMode = nil } }), presenting: proposedMode) { mode in
            Button("Cancel", role: .cancel) { proposedMode = nil }
            Button("Enable Force Quit", role: .destructive) {
                edit { $0.mode = mode }
                proposedMode = nil
            }
        } message: { mode in
            Text("Force quitting may discard unsaved work. AppSweep cannot reliably detect unsaved documents.\(mode == .normalThenForce ? " The fallback may close an app even while it is showing a save confirmation." : " This mode skips normal quit and save confirmations.")")
        }
    }
}

private struct ActivityView: View {
    @ObservedObject var monitor: InactivityMonitor
    let reviewPolicy: (String) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Recent activity").font(.title2.weight(.semibold))
                    Text("Up to 200 events from this session.").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Clear") { monitor.clearHistory() }.disabled(monitor.history.isEmpty)
            }.padding(24)
            Divider()
            List(monitor.history) { event in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: event.warning ? "exclamationmark.circle" : "clock")
                        .foregroundStyle(event.warning ? Color.orange : Color.secondary).frame(width: 20)
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(event.name).fontWeight(.medium)
                            if let pid = event.pid { Text("PID \(pid)").font(.caption.monospaced()).foregroundStyle(.secondary) }
                            Spacer()
                            Text(event.date, style: .time).font(.caption).foregroundStyle(.secondary)
                        }
                        Text(event.message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                        if event.warning, let status = monitor.orderedStatuses.first(where: { $0.id.pid == event.pid && $0.phase == .refused }) {
                            Button("Review quit options for \(status.name)…") { reviewPolicy(status.bundleID) }
                                .font(.caption)
                        }
                    }
                }.padding(.vertical, 8)
            }.listStyle(.inset)
            .overlay {
                if monitor.history.isEmpty { Text("Activity will appear as countdowns start and applications close.").foregroundStyle(.secondary).padding() }
            }
        }
    }
}

private struct GeneralView: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var login: LoginItemManager
    @State private var confirmReset = false
    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: Binding(get: { login.requested }, set: { login.setEnabled($0) }))
                Text(login.description).font(.caption).foregroundStyle(.secondary)
                if let error = login.error { Text(error).foregroundStyle(.orange).font(.caption) }
                Button("Open Login Items in System Settings") { login.openSystemSettings() }
            } header: { Text("Startup") }
            Section {
                Text("AppSweep quits selected inactive applications to reduce Dock clutter and free the memory they use.")
                Text("Unpinned app icons leave the Dock when the app quits. Pinned icons stay; remove those from the Dock manually. macOS may retain cached data after an app exits.")
                Text("AppSweep lives in the menu bar and uses no background helper. All applications start disabled.")
                Text("Normal quit is the default. Force quitting requires an explicit choice for each app and can discard unsaved work.")
                Text("Returning to an app cancels any pending force fallback. A normal quit request already sent cannot be recalled; respond to save dialogs inside the app.")
                Text("Timers restart from the full timeout after pause, sleep, session changes, or a settings change.")
            } header: { Text("Behavior & safety") }
            Section {
                Text(store.fileURL.path).font(.caption.monospaced()).textSelection(.enabled)
                Text("Settings are saved locally. Recent activity stays in memory and is cleared when AppSweep quits.").font(.caption).foregroundStyle(.secondary)
                if store.canResetUnreadableSettings { Button("Back Up and Reset Unreadable Settings…") { confirmReset = true } }
            } header: { Text("Storage") }
            Section {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")
                Text("macOS 13 or later · Swift, AppKit & SwiftUI").font(.caption).foregroundStyle(.secondary)
                LabeledContent("Made by", value: "Simon Appleton / Pocket Giant")
                Link("pocketgiant.games", destination: URL(string: "https://pocketgiant.games/")!)
            } header: { Text("AppSweep") }
        }.formStyle(.grouped).onAppear { login.refresh() }
        .alert("Reset unreadable settings?", isPresented: $confirmReset) {
            Button("Cancel", role: .cancel) {}
            Button("Back Up and Reset", role: .destructive) { store.resetUnreadableSettings() }
        } message: { Text("The existing file will be preserved as a backup. All applications will be disabled and automatic closing will remain paused.") }
    }
}
