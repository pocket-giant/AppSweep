import Foundation
import Combine
import OSLog

@MainActor
final class SettingsStore: ObservableObject {
    private struct Document: Codable {
        var version = 1
        var paused = false
        var policies: [String: AppPolicy] = [:]
    }

    @Published private(set) var policies: [String: AppPolicy] = [:]
    @Published private(set) var paused = false
    @Published private(set) var error: String?
    private var loadFailed = false
    var canResetUnreadableSettings: Bool { loadFailed }
    let fileURL: URL
    private let logger = Logger(subsystem: "local.QuietBar", category: "Settings")

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("QuietBar", isDirectory: true)
            .appendingPathComponent("settings.json", isDirectory: false)
        guard FileManager.default.fileExists(atPath: self.fileURL.path) else { return }
        do {
            let document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: self.fileURL))
            guard document.version == 1 else { throw CocoaError(.fileReadCorruptFile) }
            policies = document.policies.mapValues(\.validated)
            paused = document.paused
        } catch {
            loadFailed = true
            paused = true
            self.error = "Settings could not be read. Automatic closing is paused. Restore the settings file or reset it in General. \(error.localizedDescription)"
            logger.error("Settings load failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func policy(for id: String) -> AppPolicy { policies[id] ?? AppPolicy() }

    @discardableResult
    func update(_ policy: AppPolicy, for id: String) -> Bool {
        var updated = policies
        updated[id] = policy.validated
        guard save(policies: updated, paused: paused) else { return false }
        policies = updated
        return true
    }

    @discardableResult
    func setPaused(_ value: Bool) -> Bool {
        // Pausing remains available even if disk writes fail.
        if value { paused = true }
        guard save(policies: policies, paused: value) else { return false }
        if paused != value { paused = value }
        return true
    }

    private func save(policies: [String: AppPolicy], paused: Bool) -> Bool {
        guard !loadFailed else { return false }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(Document(paused: paused, policies: policies)).write(to: fileURL, options: .atomic)
            error = nil
            return true
        } catch {
            self.error = "Settings could not be saved: \(error.localizedDescription)"
            logger.error("Settings save failed: \(String(describing: error as NSError), privacy: .public)")
            return false
        }
    }

    func resetUnreadableSettings() {
        guard loadFailed else { return }
        do {
            let backup = fileURL.deletingLastPathComponent().appendingPathComponent("settings-backup-\(UUID().uuidString).json")
            try FileManager.default.moveItem(at: fileURL, to: backup)
            loadFailed = false
            if save(policies: [:], paused: true) {
                policies = [:]
                paused = true
            }
        } catch {
            self.error = "Could not back up the settings file: \(error.localizedDescription)"
        }
    }
}
