import AppKit
import Darwin

enum TerminationMode: String, Codable, CaseIterable, Identifiable {
    case normal, normalThenForce, force
    var id: String { rawValue }
    var title: String {
        switch self {
        case .normal: return "Normal quit"
        case .normalThenForce: return "Normal quit, then force quit"
        case .force: return "Force quit only"
        }
    }
}

struct AppPolicy: Codable, Equatable {
    var enabled = false
    var timeout: TimeInterval = 30
    var mode: TerminationMode = .normal
    var fallbackDelay: TimeInterval = 5

    var validated: AppPolicy {
        var result = self
        result.timeout = timeout.isFinite ? min(86_400, max(1, timeout)) : 30
        result.fallbackDelay = fallbackDelay.isFinite ? min(300, max(1, fallbackDelay)) : 5
        return result
    }
}

struct ProcessIdentity: Hashable {
    let pid: pid_t
    let launchDate: Date

    init?(_ app: NSRunningApplication) {
        guard let identity = ProcessLookup.snapshot(pid: app.processIdentifier)?.identity else { return nil }
        self = identity
    }

    init(pid: pid_t, launchDate: Date) {
        self.pid = pid
        self.launchDate = launchDate
    }
}

/// Public libproc APIs recover stale AppKit records without scripts or periodic polling.
enum ProcessLookup {
    struct Snapshot {
        let identity: ProcessIdentity
        let executablePath: String
    }

    static func snapshot(pid: pid_t) -> Snapshot? {
        guard pid > 1 else { return nil }
        var info = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size,
              info.pbi_uid == getuid(), info.pbi_start_tvsec > 0,
              info.pbi_status != SZOMB else { return nil }
        var path = [CChar](repeating: 0, count: Int(4 * MAXPATHLEN))
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
        let executable = URL(fileURLWithPath: String(cString: path)).resolvingSymlinksInPath().path
        let date = Date(timeIntervalSince1970: Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000)
        return Snapshot(identity: ProcessIdentity(pid: pid, launchDate: date), executablePath: executable)
    }

    static func processes(for app: NSRunningApplication) -> [Snapshot] {
        guard AppSafety.isEligible(app), let url = app.executableURL else { return [] }
        let path = url.resolvingSymlinksInPath().path
        if app.processIdentifier > 0 {
            guard let process = snapshot(pid: app.processIdentifier), process.executablePath == path else { return [] }
            return [process]
        }
        // AppKit can retain PID -1 and an old launch date after automatic termination.
        // Resolve only the exact executable, owned by this user, at workspace events.
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let received = pids.withUnsafeMutableBytes { bytes in proc_listallpids(bytes.baseAddress, Int32(bytes.count)) }
        guard received > 0 else { return [] }
        return pids.prefix(min(Int(received), pids.count)).compactMap { pid in
            guard pid > 1 else { return nil }
            // Most processes do not belong to this app. Reject by executable first
            // without resolving symlinks or reading process details for every PID.
            var candidate = [CChar](repeating: 0, count: Int(4 * MAXPATHLEN))
            guard proc_pidpath(pid, &candidate, UInt32(candidate.count)) > 0,
                  String(cString: candidate) == path else { return nil }
            guard let process = snapshot(pid: pid), process.executablePath == path else { return nil }
            return process
        }
    }

    /// The monitor must also authorize the policy, pause state and foreground state.
    /// Recheck kernel identity immediately at the public POSIX signal boundary.
    static func forceQuitVerifiedProcess(_ identity: ProcessIdentity, executablePath: String) -> Bool {
        guard identity.pid != ProcessInfo.processInfo.processIdentifier,
              let current = snapshot(pid: identity.pid), current.identity == identity,
              current.executablePath == executablePath else { return false }
        return Darwin.kill(identity.pid, SIGKILL) == 0
    }
}

enum AppSafety {
    static let protectedIDs: Set<String> = [
        "com.apple.finder", "com.apple.dock", "com.apple.loginwindow",
        "com.apple.SystemUIServer", "com.apple.controlcenter", "com.apple.Spotlight",
        "com.apple.notificationcenterui", "com.apple.WindowManager",
        "com.apple.SecurityAgent", "com.apple.ScreenSaver.Engine",
        "com.apple.UserNotificationCenter", "com.apple.SoftwareUpdateNotificationManager"
    ]

    static func exclusionReason(bundleID: String, url: URL?) -> String? {
        if bundleID == Bundle.main.bundleIdentifier { return "AppSweep protects itself" }
        if protectedIDs.contains(bundleID) { return "Essential macOS application" }
        if let path = url?.resolvingSymlinksInPath().path,
           path.hasPrefix("/System/Library/") || path.hasPrefix("/usr/")
            || (path.hasPrefix("/System/Volumes/") && path.contains("/System/Library/")) {
            return "macOS system component"
        }
        return nil
    }

    static func isEligible(_ app: NSRunningApplication) -> Bool {
        guard !app.isTerminated, app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              app.activationPolicy == .regular, let id = app.bundleIdentifier,
              exclusionReason(bundleID: id, url: app.bundleURL) == nil else { return false }
        return true
    }

    static func canManage(_ app: NSRunningApplication) -> Bool {
        isEligible(app) && ProcessIdentity(app) != nil
    }
}

struct InstalledApp: Identifiable {
    let id: String // Bundle identifier: settings survive updates and relaunches.
    let name: String
    let url: URL?
    let protection: String?
}

enum ProcessPhase: Equatable {
    case active, idle, countdown, quitting, forcing, refused
    var title: String {
        switch self {
        case .active: return "Active"
        case .idle: return "Not scheduled"
        case .countdown: return "Countdown"
        case .quitting: return "Waiting for quit"
        case .forcing: return "Force quit requested"
        case .refused: return "Still running · quit refused or awaiting a response"
        }
    }
}

struct ProcessStatus: Identifiable {
    let id: ProcessIdentity
    let bundleID: String
    let name: String
    var phase: ProcessPhase
    var deadline: TimeInterval?
    var detail: String?

    var remainingSeconds: Int {
        max(0, Int(ceil((deadline ?? ProcessInfo.processInfo.systemUptime) - ProcessInfo.processInfo.systemUptime)))
    }
}

struct ActivityEvent: Identifiable {
    let id = UUID()
    let date = Date()
    let name: String
    let pid: pid_t?
    let message: String
    let warning: Bool
}
