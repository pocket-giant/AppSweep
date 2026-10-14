import AppKit

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
        guard app.processIdentifier > 0, let date = app.launchDate else { return nil }
        pid = app.processIdentifier
        launchDate = date
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
        if bundleID == Bundle.main.bundleIdentifier { return "QuietBar protects itself" }
        if protectedIDs.contains(bundleID) { return "Essential macOS application" }
        if let path = url?.resolvingSymlinksInPath().path,
           path.hasPrefix("/System/Library/") || path.hasPrefix("/usr/")
            || (path.hasPrefix("/System/Volumes/") && path.contains("/System/Library/")) {
            return "macOS system component"
        }
        return nil
    }

    static func canManage(_ app: NSRunningApplication) -> Bool {
        guard !app.isTerminated, app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              app.activationPolicy == .regular, let id = app.bundleIdentifier,
              exclusionReason(bundleID: id, url: app.bundleURL) == nil,
              ProcessIdentity(app) != nil else { return false }
        return true
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
