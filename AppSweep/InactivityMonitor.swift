import AppKit
import Combine
import OSLog

/// All workspace events, policy changes, and timer callbacks are serialized on the main actor.
@MainActor
final class InactivityMonitor: ObservableObject {
    private final class Entry {
        let identity: ProcessIdentity
        // KVO tokens do not keep NSRunningApplication alive. Retain the observed object
        // for exactly the lifetime of the tracked process, and invalidate before release.
        let observedApplication: NSRunningApplication
        let bundleID: String
        let name: String
        let executablePath: String
        var timer: Timer?
        var generation = UUID()
        var terminationObservation: NSKeyValueObservation?
        init(app: NSRunningApplication, process: ProcessLookup.Snapshot, bundleID: String) {
            self.identity = process.identity
            executablePath = process.executablePath
            observedApplication = app
            self.bundleID = bundleID
            name = app.localizedName ?? bundleID
        }
        func cancel() { timer?.invalidate(); timer = nil; generation = UUID() }
        deinit { timer?.invalidate(); terminationObservation?.invalidate() }
    }

    @Published private(set) var statuses: [ProcessIdentity: ProcessStatus] = [:]
    @Published private(set) var history: [ActivityEvent] = []
    @Published private(set) var suspended = false
    private let store: SettingsStore
    private var entries: [ProcessIdentity: Entry] = [:]
    private var subscriptions = Set<AnyCancellable>()
    private var previousPolicies: [String: AppPolicy]
    private var sleeping = false
    private var sessionInactive = false
    private let logger = Logger(subsystem: "local.QuietBar", category: "Monitor")

    var isPaused: Bool { store.paused || suspended }
    var orderedStatuses: [ProcessStatus] {
        statuses.values.sorted {
            if $0.phase == .countdown && $1.phase != .countdown { return true }
            if $1.phase == .countdown && $0.phase != .countdown { return false }
            return ($0.name, $0.id.pid) < ($1.name, $1.id.pid)
        }
    }

    init(store: SettingsStore) {
        self.store = store
        previousPolicies = store.policies
        let center = NSWorkspace.shared.notificationCenter
        observe(center, NSWorkspace.didActivateApplicationNotification) { [weak self] in self?.activated($0) }
        observe(center, NSWorkspace.didDeactivateApplicationNotification) { [weak self] in self?.deactivated($0) }
        observe(center, NSWorkspace.didLaunchApplicationNotification) { [weak self] in self?.launched($0) }
        observe(center, NSWorkspace.didTerminateApplicationNotification) { [weak self] note in
            guard let self,
                  let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            for entry in Array(self.entries.values) where entry.bundleID == app.bundleIdentifier {
                if ProcessLookup.snapshot(pid: entry.identity.pid)?.identity != entry.identity { self.terminated(entry.identity) }
            }
        }
        observe(center, NSWorkspace.willSleepNotification) { [weak self] _ in
            self?.sleeping = true; self?.updateSuspension()
        }
        observe(center, NSWorkspace.didWakeNotification) { [weak self] _ in
            self?.sleeping = false; self?.updateSuspension()
        }
        observe(center, NSWorkspace.sessionDidResignActiveNotification) { [weak self] _ in
            self?.sessionInactive = true; self?.updateSuspension()
        }
        observe(center, NSWorkspace.sessionDidBecomeActiveNotification) { [weak self] _ in
            self?.sessionInactive = false; self?.updateSuspension()
        }
        store.$policies.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] policies in
            self?.policiesChanged(policies)
        }.store(in: &subscriptions)
        store.$paused.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] paused in
            guard let self else { return }
            self.cancelAll()
            self.record("AppSweep", nil, paused ? "Automatic closing paused" : "Automatic closing resumed; fresh countdowns started")
            if !paused && !self.suspended { self.resync() }
        }.store(in: &subscriptions)
        resync()
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         action: @escaping (Notification) -> Void) {
        center.publisher(for: name).receive(on: DispatchQueue.main).sink(receiveValue: action).store(in: &subscriptions)
    }

    private func track(_ app: NSRunningApplication) -> [Entry] {
        guard AppSafety.isEligible(app), let bundleID = app.bundleIdentifier else { return [] }
        return ProcessLookup.processes(for: app).map { process in
            let identity = process.identity
            if let entry = entries[identity] { return entry }
            for old in Array(entries.keys) where old.pid == identity.pid && old != identity { remove(old) }
            let entry = Entry(app: app, process: process, bundleID: bundleID)
            entries[identity] = entry
            statuses[identity] = ProcessStatus(id: identity, bundleID: bundleID, name: entry.name,
                phase: isActive(app, identity: identity) ? .active : .idle)
            entry.terminationObservation = app.observe(\.isTerminated, options: [.new]) { [weak self] app, _ in
                guard app.isTerminated else { return }
                Task { @MainActor [weak self] in
                    if ProcessLookup.snapshot(pid: identity.pid)?.identity != identity { self?.terminated(identity) }
                }
            }
            if app.processIdentifier != identity.pid {
                record(entry.name, identity.pid, "Recovered live process identity from stale macOS application record")
            }
            return entry
        }
    }

    private func isActive(_ app: NSRunningApplication, identity: ProcessIdentity? = nil) -> Bool {
        if app.isActive { return true }
        guard let front = NSWorkspace.shared.frontmostApplication else { return false }
        if let frontIdentity = ProcessIdentity(front), let identity { return frontIdentity == identity }
        // A stale foreground record has no trustworthy PID. Protect every instance
        // of its bundle conservatively until macOS identifies a different active app.
        return front.bundleIdentifier == app.bundleIdentifier
    }

    private func liveApplication(_ entry: Entry) -> NSRunningApplication? {
        guard let process = ProcessLookup.snapshot(pid: entry.identity.pid),
              process.identity == entry.identity, process.executablePath == entry.executablePath else { return nil }
        let app = NSRunningApplication(processIdentifier: entry.identity.pid) ?? entry.observedApplication
        guard app.bundleIdentifier == entry.bundleID, AppSafety.isEligible(app),
              app.executableURL?.resolvingSymlinksInPath().path == entry.executablePath else { return nil }
        return app
    }

    private func activated(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        let activatedEntries = track(app)
        let activeIdentities = Set(activatedEntries.map(\.identity))
        for entry in activatedEntries {
            let hadWork = entry.timer != nil
            entry.cancel()
            setStatus(entry, .active)
            if hadWork { record(entry.name, entry.identity.pid, "Countdown or force fallback cancelled: application active") }
        }
        for entry in Array(entries.values) where !activeIdentities.contains(entry.identity)
            && statuses[entry.identity]?.phase == .active {
            startCountdown(entry)
        }
    }

    private func deactivated(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        for entry in track(app) where statuses[entry.identity]?.phase == .active { startCountdown(entry) }
    }

    private func launched(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        for entry in track(app) where !isActive(app, identity: entry.identity) { startCountdown(entry) }
    }

    private func resync() {
        for identity in Array(entries.keys) {
            if ProcessLookup.snapshot(pid: identity.pid)?.identity != identity { terminated(identity) }
        }
        for app in NSWorkspace.shared.runningApplications {
            for entry in track(app) {
                entry.cancel()
                if isActive(app, identity: entry.identity) { setStatus(entry, .active) } else { startCountdown(entry) }
            }
        }
    }

    private func policiesChanged(_ policies: [String: AppPolicy]) {
        let changed = Set(previousPolicies.keys).union(policies.keys).filter { previousPolicies[$0] != policies[$0] }
        previousPolicies = policies
        for entry in Array(entries.values) where changed.contains(entry.bundleID) {
            entry.cancel()
            guard let app = liveApplication(entry) else { remove(entry.identity); continue }
            if isActive(app, identity: entry.identity) { setStatus(entry, .active) } else { startCountdown(entry) }
        }
    }

    private func startCountdown(_ entry: Entry) {
        entry.cancel()
        guard let app = liveApplication(entry) else { remove(entry.identity); return }
        guard !isActive(app, identity: entry.identity) else { setStatus(entry, .active); return }
        let policy = store.policy(for: entry.bundleID)
        guard !isPaused, policy.enabled else { setStatus(entry, .idle); return }
        setStatus(entry, .countdown, delay: policy.timeout)
        record(entry.name, entry.identity.pid, "Inactive: \(Int(policy.timeout))s countdown started")
        arm(entry, delay: policy.timeout) { [weak self] in self?.requestQuit($0) }
    }

    /// Both normal and forced termination pass this guard immediately before sending a request.
    private func permittedApplication(_ entry: Entry) -> NSRunningApplication? {
        guard !isPaused, store.policy(for: entry.bundleID).enabled,
              let app = liveApplication(entry) else {
            entry.cancel()
            if liveApplication(entry) == nil { remove(entry.identity) } else { setStatus(entry, .idle) }
            return nil
        }
        guard !isActive(app, identity: entry.identity) else {
            entry.cancel(); setStatus(entry, .active)
            record(entry.name, entry.identity.pid, "Quit cancelled: application is active")
            return nil
        }
        return app
    }

    private func requestQuit(_ entry: Entry) {
        guard let app = permittedApplication(entry) else { return }
        let policy = store.policy(for: entry.bundleID)
        if policy.mode == .force { requestForceQuit(entry); return }
        setStatus(entry, .quitting, delay: policy.mode == .normalThenForce ? policy.fallbackDelay : nil)
        let accepted = app.processIdentifier <= 0 || ProcessIdentity(app) == entry.identity ? app.terminate() : false
        record(entry.name, entry.identity.pid, accepted ? "Normal quit requested" : "Application did not accept normal quit", warning: !accepted)
        if ProcessLookup.snapshot(pid: entry.identity.pid)?.identity != entry.identity { terminated(entry.identity); return }
        if policy.mode == .normalThenForce {
            arm(entry, delay: policy.fallbackDelay) { [weak self] in self?.requestForceQuit($0) }
        } else if accepted {
            // Observe once, without polling or sending repeat termination requests.
            arm(entry, delay: 5) { [weak self] in self?.checkTermination($0) }
        } else {
            setStatus(entry, .refused, detail: "Normal quit was declined. Choose a force fallback in Quit strength for stubborn apps, or return and switch away to try normal quit again.")
        }
    }

    private func requestForceQuit(_ entry: Entry) {
        guard let app = permittedApplication(entry) else { return }
        let policy = store.policy(for: entry.bundleID)
        // Never infer force permission from the previous state or a failed normal request.
        guard policy.mode == .force || policy.mode == .normalThenForce else {
            entry.cancel(); setStatus(entry, .idle); return
        }
        setStatus(entry, .forcing)
        var accepted = ProcessIdentity(app) == entry.identity ? app.forceTerminate() : false
        if !accepted || app.processIdentifier != entry.identity.pid {
            // AppKit may send nothing when its cached PID is -1. An explicitly
            // enabled force mode may use the public POSIX signal API after all
            // identity, owner, executable, foreground, and policy checks pass again.
            if let checked = permittedApplication(entry),
               store.policy(for: entry.bundleID).mode != .normal,
               !isActive(checked, identity: entry.identity),
               let process = ProcessLookup.snapshot(pid: entry.identity.pid),
               process.identity == entry.identity, process.executablePath == entry.executablePath {
                accepted = ProcessLookup.forceQuitVerifiedProcess(entry.identity, executablePath: entry.executablePath)
                if accepted { record(entry.name, entry.identity.pid, "Force quit sent directly to verified live process; AppKit force quit was unavailable", warning: true) }
            } else { return }
        }
        record(entry.name, entry.identity.pid, accepted ? "Force quit explicitly enabled: request sent" : "Force quit request failed", warning: true)
        if ProcessLookup.snapshot(pid: entry.identity.pid)?.identity != entry.identity { terminated(entry.identity); return }
        if accepted { arm(entry, delay: 2) { [weak self] in self?.checkTermination($0) } }
        else { setStatus(entry, .refused, detail: "macOS did not accept the force quit request. No automatic retries.") }
    }

    private func checkTermination(_ entry: Entry) {
        guard let app = liveApplication(entry) else { terminated(entry.identity); return }
        guard !isActive(app, identity: entry.identity) else { entry.cancel(); setStatus(entry, .active); return }
        let forced = statuses[entry.identity]?.phase == .forcing
        setStatus(entry, .refused, detail: forced
            ? "Still running after force quit. No automatic retries."
            : "The app did not exit after normal quit. The reason is unknown; this does not mean it has unsaved work. Choose a force fallback in Quit strength to close stubborn apps.")
        record(entry.name, entry.identity.pid, forced ? "Still running after force quit" : "Still running after normal quit. Reason unknown; force fallback is off.", warning: true)
    }

    private func arm(_ entry: Entry, delay: TimeInterval, action: @escaping (Entry) -> Void) {
        entry.cancel()
        let generation = entry.generation
        let identity = entry.identity
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            // The timer lives on the main run loop. A queued callback still checks its generation.
            MainActor.assumeIsolated {
                guard let self, let current = self.entries[identity], current.generation == generation else { return }
                current.timer = nil
                action(current)
            }
        }
        timer.tolerance = min(0.1, delay * 0.01)
        entry.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func setStatus(_ entry: Entry, _ phase: ProcessPhase, delay: TimeInterval? = nil, detail: String? = nil) {
        statuses[entry.identity] = ProcessStatus(id: entry.identity, bundleID: entry.bundleID,
            name: entry.name, phase: phase, deadline: delay.map { ProcessInfo.processInfo.systemUptime + $0 }, detail: detail)
    }

    private func terminated(_ identity: ProcessIdentity) {
        guard let entry = entries[identity] else { return }
        let phase = statuses[identity]?.phase
        if phase == .quitting || phase == .forcing || phase == .refused {
            record(entry.name, identity.pid, "Application exited")
        }
        remove(identity)
    }

    private func remove(_ identity: ProcessIdentity) {
        entries.removeValue(forKey: identity)?.cancel()
        statuses.removeValue(forKey: identity)
    }

    private func cancelAll() {
        for entry in Array(entries.values) {
            entry.cancel()
            if let app = liveApplication(entry) { setStatus(entry, isActive(app, identity: entry.identity) ? .active : .idle) }
            else { remove(entry.identity) }
        }
    }

    private func updateSuspension() {
        let value = sleeping || sessionInactive
        guard value != suspended else { return }
        suspended = value
        cancelAll()
        record("AppSweep", nil, value ? "Countdowns cancelled while Mac sleeps or session is inactive" : "Session resumed; fresh countdowns started")
        if !value && !store.paused { resync() }
    }

    private func record(_ name: String, _ pid: pid_t?, _ message: String, warning: Bool = false) {
        history.insert(ActivityEvent(name: name, pid: pid, message: message, warning: warning), at: 0)
        if history.count > 200 { history.removeLast(history.count - 200) }
        if warning { logger.notice("\(name, privacy: .public) [\(pid ?? 0)]: \(message, privacy: .public)") }
        else { logger.info("\(name, privacy: .public) [\(pid ?? 0)]: \(message, privacy: .public)") }
    }

    func clearHistory() { history = [] }
    func shutdown() { cancelAll(); subscriptions.removeAll(); entries.removeAll(); statuses.removeAll() }
}
