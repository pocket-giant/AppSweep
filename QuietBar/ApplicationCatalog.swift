import AppKit
import Combine
import CoreServices
import OSLog

private final class DiscoveryCallback {
    let changed: @MainActor (Bool) -> Void
    init(changed: @escaping @MainActor (Bool) -> Void) { self.changed = changed }
}

/// Scans app folders off the main thread; directory events trigger debounced rescans.
@MainActor
final class ApplicationCatalog: ObservableObject {
    @Published private(set) var apps: [InstalledApp] = []
    @Published private(set) var scanning = false
    private let queue = DispatchQueue(label: "local.QuietBar.catalog", qos: .utility)
    private var eventStream: FSEventStreamRef?
    private var restartStreamAfterScan = false
    private var refreshTask: Task<Void, Never>?
    private var subscriptions = Set<AnyCancellable>()
    private var rescanRequested = false
    private let logger = Logger(subsystem: "local.QuietBar", category: "Catalog")
    private let roots = [URL(fileURLWithPath: "/Applications"),
                         FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
                         URL(fileURLWithPath: "/System/Applications"),
                         URL(fileURLWithPath: "/System/Volumes/Preboot/Cryptexes/App/System/Applications")]

    init() {
        let center = NSWorkspace.shared.notificationCenter
        for event in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                      NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            center.publisher(for: event).receive(on: DispatchQueue.main).sink { [weak self] _ in
                self?.scheduleRefresh()
            }.store(in: &subscriptions)
        }
        startDiscoveryEvents()
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
        let roots = self.roots
        queue.async { [weak self] in
            var urls = Set(runningURLs)
            for root in roots where FileManager.default.fileExists(atPath: root.path) {
                guard let iterator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
                for case let url as URL in iterator {
                    if url.pathExtension.lowercased() == "app" {
                        urls.insert(url)
                        iterator.skipDescendants()
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
                if self.restartStreamAfterScan {
                    self.restartStreamAfterScan = false
                    self.startDiscoveryEvents()
                }
                if self.rescanRequested {
                    self.rescanRequested = false
                    self.scheduleRefresh()
                }
            }
        }
    }

    private func startDiscoveryEvents() {
        if let eventStream {
            FSEventStreamStop(eventStream)
            FSEventStreamInvalidate(eventStream)
            FSEventStreamRelease(eventStream)
            self.eventStream = nil
        }
        // One recursive stream for all application folders. Opening a descriptor for
        // every subfolder exhausts macOS's per-process limit, breaking fonts and writes.
        let callback = DiscoveryCallback { [weak self] rootChanged in
            guard let self else { return }
            self.restartStreamAfterScan = self.restartStreamAfterScan || rootChanged
            self.scheduleRefresh()
        }
        var context = FSEventStreamContext(version: 0,
            info: Unmanaged.passUnretained(callback).toOpaque(),
            retain: { info in
                guard let info else { return nil }
                _ = Unmanaged<DiscoveryCallback>.fromOpaque(info).retain()
                return info
            },
            release: { info in
                guard let info else { return }
                Unmanaged<DiscoveryCallback>.fromOpaque(info).release()
            }, copyDescription: nil)
        guard let stream = FSEventStreamCreate(kCFAllocatorDefault, { _, info, count, _, flags, _ in
            guard let info else { return }
            let callback = Unmanaged<DiscoveryCallback>.fromOpaque(info).takeUnretainedValue()
            let rootChanged = (0..<count).contains { flags[$0] & UInt32(kFSEventStreamEventFlagRootChanged) != 0 }
            MainActor.assumeIsolated { callback.changed(rootChanged) }
        }, &context, roots.map(\.path) as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.5,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagWatchRoot)) else {
            logger.error("Could not create application discovery stream; manual refresh remains available")
            return
        }
        FSEventStreamSetDispatchQueue(stream, .main)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            logger.error("Could not start application discovery stream; manual refresh remains available")
            return
        }
        eventStream = stream
    }

    deinit {
        if let eventStream {
            FSEventStreamStop(eventStream)
            FSEventStreamInvalidate(eventStream)
            FSEventStreamRelease(eventStream)
        }
    }
}
