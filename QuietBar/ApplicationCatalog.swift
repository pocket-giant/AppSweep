import AppKit
import Combine
import OSLog

/// Scans app folders off the main thread; directory events trigger debounced rescans.
@MainActor
final class ApplicationCatalog: ObservableObject {
    @Published private(set) var apps: [InstalledApp] = []
    @Published private(set) var scanning = false
    private let queue = DispatchQueue(label: "local.QuietBar.catalog", qos: .utility)
    private var watchers: [String: DispatchSourceFileSystemObject] = [:]
    private var refreshTask: Task<Void, Never>?
    private var subscriptions = Set<AnyCancellable>()
    private var rescanRequested = false
    private let logger = Logger(subsystem: "local.QuietBar", category: "Catalog")

    init() {
        let center = NSWorkspace.shared.notificationCenter
        for event in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                      NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            center.publisher(for: event).receive(on: DispatchQueue.main).sink { [weak self] _ in
                self?.scheduleRefresh()
            }.store(in: &subscriptions)
        }
        refresh()
    }

    func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    func refresh() {
        guard !scanning else { rescanRequested = true; return }
        scanning = true
        let runningURLs = NSWorkspace.shared.runningApplications.compactMap(\.bundleURL)
        let roots = [URL(fileURLWithPath: "/Applications"),
                     FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
                     URL(fileURLWithPath: "/System/Applications"),
                     URL(fileURLWithPath: "/System/Volumes/Preboot/Cryptexes/App/System/Applications")]
        queue.async { [weak self] in
            var urls = Set(runningURLs)
            var directories = Set<URL>()
            // Watch parents too, so creation/replacement of an Applications folder is discovered.
            directories.insert(FileManager.default.homeDirectoryForCurrentUser)
            directories.insert(URL(fileURLWithPath: "/"))
            for root in roots where FileManager.default.fileExists(atPath: root.path) {
                directories.insert(root)
                guard let iterator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
                for case let url as URL in iterator {
                    if url.pathExtension.lowercased() == "app" {
                        urls.insert(url)
                        iterator.skipDescendants()
                    } else if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                        directories.insert(url)
                    }
                }
            }
            var found: [String: InstalledApp] = [:]
            for url in urls.sorted(by: { $0.path < $1.path }) {
                guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { continue }
                let background = (bundle.object(forInfoDictionaryKey: "LSUIElement") as? Bool == true)
                    || (bundle.object(forInfoDictionaryKey: "LSBackgroundOnly") as? Bool == true)
                let reason = AppSafety.exclusionReason(bundleID: id, url: url)
                    ?? (background ? "Background application" : nil)
                let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                    ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                    ?? url.deletingPathExtension().lastPathComponent
                if found[id] == nil { found[id] = InstalledApp(id: id, name: name, url: url, protection: reason) }
            }
            let result = Array(found.values).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.apps = result
                self.scanning = false
                self.installWatchers(directories)
                if self.rescanRequested {
                    self.rescanRequested = false
                    self.scheduleRefresh()
                }
            }
        }
    }

    private func installWatchers(_ directories: Set<URL>) {
        let paths = Set(directories.map(\.path))
        for path in Array(watchers.keys) where !paths.contains(path) { watchers.removeValue(forKey: path)?.cancel() }
        for path in paths where watchers[path] == nil {
            let fd = open(path, O_EVTONLY)
            guard fd >= 0 else { logger.debug("Cannot watch folder \(path, privacy: .public)"); continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd,
                eventMask: [.write, .rename, .delete, .revoke], queue: .main)
            source.setEventHandler { [weak self, weak source] in
                if let source, !source.data.intersection([.rename, .delete, .revoke]).isEmpty {
                    self?.watchers.removeValue(forKey: path)?.cancel()
                }
                self?.scheduleRefresh()
            }
            source.setCancelHandler { close(fd) }
            watchers[path] = source
            source.resume()
        }
    }

    deinit { watchers.values.forEach { $0.cancel() } }
}
