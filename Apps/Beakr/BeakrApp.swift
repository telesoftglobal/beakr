//
//  BeakrApp.swift
//  Beakr
//
//  Created by Ice-9 on 2026-10-03.
//

import SwiftUI
import AppIntents
import Darwin
import BeakrNetCore
#if os(macOS)
import AppKit
#endif

@main
@MainActor
struct BeakrApp: App {
    @State private var applicationModel: BeakrApplicationModel
#if os(macOS)
    @NSApplicationDelegateAdaptor(BeakrApplicationDelegate.self) private var applicationDelegate
#endif

    init() {
#if os(macOS)
        NSLog("[APP-OWNERSHIP] pid=%d stage=startup-enter", getpid())
        MacApplicationOwnership.requireOwnership()
        NSLog("[APP-OWNERSHIP] pid=%d stage=storage-owned", getpid())
#endif
        _applicationModel = State(initialValue: BeakrApplicationModel())
    }

    var body: some Scene {
#if os(macOS)
        Window("Beakr", id: "main") {
            ContentView(
                model: applicationModel.messageComposer,
                bootstrap: applicationModel.bootstrap
            )
            .background(MacMainWindowPlacement())
            .task {
                applicationDelegate.terminationHandler = {
                    await applicationModel.terminate()
                }
                NSLog("[APP-OWNERSHIP] pid=%d stage=termination-handler-installed", getpid())
                MacApplicationOwnership.enableReplacementRequests()
                await applicationModel.start()
                NSLog("[APP-OWNERSHIP] pid=%d stage=startup-task-complete", getpid())
            }
        }
        .defaultSize(width: 1_200, height: 760)
        // The placement record below owns restoration, including display identity.
        .restorationBehavior(.disabled)
        .windowToolbarStyle(.unified)
        .commands {
            BeakrMainWindowCommands()
        }

        Settings {
            BeakrSettingsView(bootstrap: applicationModel.bootstrap)
                .background(MacSecondaryWindowPlacement(role: .secondary))
                .windowResizeBehavior(.enabled)
        }
        .defaultSize(width: 820, height: 600)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified)
#else
        WindowGroup {
            ContentView(
                model: applicationModel.messageComposer,
                bootstrap: applicationModel.bootstrap
            )
        }
#endif
    }
}

@MainActor
@Observable
private final class BeakrApplicationModel {
    let messageComposer: MessageComposerModel
    let bootstrap: NodeBootstrapModel
    let statusIntentAdapter: StatusIntentAdapter

    init() {
        let inbox = ApplicationMessageInbox()
        let deliveryUpdates = ApplicationDeliveryUpdates()
        messageComposer = MessageComposerModel(
            messagingService: UnconfiguredHostMessagingService(),
            inbox: inbox,
            deliveryUpdates: deliveryUpdates
        )
        let statusPermissions = SharedStatusPermissionCoordinator()
        let composer = messageComposer
        let lanRuntime = ApplicationLANRuntimeManager(
            inbox: inbox,
            deliveryUpdates: deliveryUpdates,
            statusPermissions: statusPermissions,
            mailboxMetadataAttachment: { url in
                composer.attachMailboxMetadata(fileURL: url)
            }
        )
        messageComposer.replaceMessagingService(lanRuntime)
        bootstrap = NodeBootstrapModel(lanRuntimeManager: lanRuntime, statusPermissions: statusPermissions)
        let adapter = StatusIntentAdapter(bootstrap: bootstrap)
        statusIntentAdapter = adapter
        AppDependencyManager.shared.add(dependency: adapter)
    }

    func start() async {
        await bootstrap.start()
    }

    func terminate() async {
        await bootstrap.applicationWillTerminate()
    }
}

#if os(macOS)
/// Measures Column 1 directly, without depending on SwiftUI's private split-view hierarchy.
struct MacSecondaryWindowPlacement: NSViewRepresentable {
    enum Role { case sidebar, secondary }
    let role: Role
    var sizePreferenceKey: String? = nil

    func makeNSView(context: Context) -> PlacementView {
        PlacementView(role: role, sizePreferenceKey: sizePreferenceKey)
    }
    func updateNSView(_ nsView: PlacementView, context: Context) {}

    @MainActor
    final class PlacementView: NSView {
        static weak var mainWindow: NSWindow?
        private static weak var sidebarView: PlacementView?
        private let role: Role
        private let sizePreferenceKey: String?
        private weak var observedWindow: NSWindow?
        private var hasPlaced = false

        init(role: Role, sizePreferenceKey: String?) {
            self.role = role
            self.sizePreferenceKey = sizePreferenceKey
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if role == .sidebar {
                if window != nil { Self.sidebarView = self }
                return
            }
            guard window !== observedWindow else { return }
            NotificationCenter.default.removeObserver(self)
            observedWindow = window
            hasPlaced = false
            guard let window else { return }
            let center = NotificationCenter.default
            center.addObserver(self, selector: #selector(placeIfNeeded), name: NSWindow.didBecomeKeyNotification, object: window)
            center.addObserver(self, selector: #selector(windowWillClose), name: NSWindow.willCloseNotification, object: window)
            if sizePreferenceKey != nil {
                for name in [NSWindow.didEndLiveResizeNotification] {
                    center.addObserver(self, selector: #selector(saveSize), name: name, object: window)
                }
            }
            // Handles attachment after the initial key-window notification.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window?.isVisible == true else { return }
                self.placeIfNeeded()
            }
        }

        @objc private func windowWillClose() {
            saveSize()
            hasPlaced = false
        }

        @objc private func saveSize() {
            guard hasPlaced, let sizePreferenceKey, let window = observedWindow,
                  !window.isMiniaturized, !window.styleMask.contains(.fullScreen) else { return }
            let size = window.frame.size
            guard size.width.isFinite, size.height.isFinite,
                  size.width > 0, size.height > 0,
                  let data = try? JSONEncoder().encode(size) else { return }
            UserDefaults.standard.set(data, forKey: sizePreferenceKey)
        }

        @objc private func placeIfNeeded() {
            guard !hasPlaced, let window = observedWindow else { return }
            guard let source = Self.mainWindow, source !== window,
                  source.isVisible, !source.isMiniaturized,
                  let screen = source.screen else { return }
            source.contentView?.layoutSubtreeIfNeeded()
            var left = source.frame.minX
            if let sidebar = Self.sidebarView, sidebar.window === source,
               !sidebar.isHiddenOrHasHiddenAncestor, sidebar.visibleRect.width > 0 {
                left = source.convertToScreen(sidebar.convert(sidebar.bounds, to: nil)).maxX
            }
            let visible = screen.visibleFrame
            var size = window.frame.size
            if let sizePreferenceKey,
               let data = UserDefaults.standard.data(forKey: sizePreferenceKey),
               let saved = try? JSONDecoder().decode(CGSize.self, from: data),
               saved.width.isFinite, saved.height.isFinite,
               saved.width > 0, saved.height > 0 {
                size = CGSize(
                    width: max(saved.width, window.minSize.width),
                    height: max(saved.height, window.minSize.height)
                )
            }
            // Restore dimensions independently; every opening still aligns with Column 1.
            // Preserve size. If larger than the display, keep the title bar reachable.
            let origin = CGPoint(
                x: min(max(left, visible.minX), max(visible.minX, visible.maxX - size.width)),
                y: min(max(source.frame.maxY, min(visible.maxY, visible.minY + size.height)), visible.maxY) - size.height
            )
            window.setFrame(CGRect(origin: origin, size: size), display: true)
            hasPlaced = true
        }
    }
}

private struct MacMainWindowPlacement: NSViewRepresentable {
    func makeNSView(context: Context) -> PlacementView { PlacementView() }
    func updateNSView(_ nsView: PlacementView, context: Context) {}

    @MainActor
    final class PlacementView: NSView {
        private static let preferenceKey = "net.beakr.mainWindow.placement.v1"

        private struct SavedPlacement: Codable {
            let displayUUID: String
            let size: CGSize
            let offsetFromTopLeft: CGPoint

            var isValid: Bool {
                size.width.isFinite && size.height.isFinite
                    && size.width > 0 && size.height > 0
                    && offsetFromTopLeft.x.isFinite && offsetFromTopLeft.y.isFinite
            }
        }

        private weak var observedWindow: NSWindow?
        private var hasRestored = false
        private var isApplyingFrame = false
        private var isChangingFullScreen = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window !== observedWindow else { return }
            NotificationCenter.default.removeObserver(self)
            observedWindow = window
            hasRestored = false
            guard let window else { return }
            MacSecondaryWindowPlacement.PlacementView.mainWindow = window
            let center = NotificationCenter.default
            center.addObserver(self, selector: #selector(windowBecameKey), name: NSWindow.didBecomeKeyNotification, object: window)
            for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification,
                         NSWindow.didChangeScreenNotification, NSWindow.willCloseNotification] {
                center.addObserver(self, selector: #selector(savePlacement), name: name, object: window)
            }
            center.addObserver(self, selector: #selector(savePlacement), name: NSApplication.willTerminateNotification, object: nil)
            center.addObserver(self, selector: #selector(willEnterFullScreen), name: NSWindow.willEnterFullScreenNotification, object: window)
            center.addObserver(self, selector: #selector(didExitFullScreen), name: NSWindow.didExitFullScreenNotification, object: window)
            // Wait for SwiftUI's initial sizing; later view updates never reposition the window.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window?.isVisible == true else { return }
                self.restorePlacement()
            }
        }

        @objc private func windowBecameKey() { restorePlacement() }
        @objc private func willEnterFullScreen() {
            savePlacement()
            isChangingFullScreen = true
        }
        @objc private func didExitFullScreen() { isChangingFullScreen = false }

        private func restorePlacement() {
            guard !hasRestored, let window = observedWindow else { return }
            hasRestored = true
            guard let data = UserDefaults.standard.data(forKey: Self.preferenceKey),
                  let saved = try? JSONDecoder().decode(SavedPlacement.self, from: data),
                  saved.isValid,
                  let screen = NSScreen.screens.first(where: { Self.displayUUID($0) == saved.displayUUID })
                    ?? window.screen ?? NSScreen.screens.first else { return }
            let visible = screen.visibleFrame
            let size = CGSize(
                width: min(max(saved.size.width, window.minSize.width), visible.width),
                height: min(max(saved.size.height, window.minSize.height), visible.height)
            )
            let frame = CGRect(
                x: min(max(visible.minX + saved.offsetFromTopLeft.x, visible.minX), visible.maxX - size.width),
                y: min(max(visible.maxY - saved.offsetFromTopLeft.y - size.height, visible.minY), visible.maxY - size.height),
                width: size.width, height: size.height
            )
            isApplyingFrame = true
            window.setFrame(frame, display: true)
            isApplyingFrame = false
        }

        @objc private func savePlacement() {
            guard hasRestored, !isApplyingFrame, !isChangingFullScreen,
                  let window = observedWindow, !window.isMiniaturized,
                  !window.styleMask.contains(.fullScreen),
                  let screen = window.screen, let uuid = Self.displayUUID(screen) else { return }
            let frame = window.frame
            let visible = screen.visibleFrame
            let saved = SavedPlacement(
                displayUUID: uuid, size: frame.size,
                offsetFromTopLeft: CGPoint(x: frame.minX - visible.minX, y: visible.maxY - frame.maxY)
            )
            guard saved.isValid, let data = try? JSONEncoder().encode(saved) else { return }
            UserDefaults.standard.set(data, forKey: Self.preferenceKey)
        }

        private static func displayUUID(_ screen: NSScreen) -> String? {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() else { return nil }
            return CFUUIDCreateString(nil, uuid) as String
        }
    }
}

@MainActor
private final class BeakrApplicationDelegate: NSObject, NSApplicationDelegate {
    var terminationHandler: (@MainActor () async -> Void)?
    private var terminationIsInProgress = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        NSLog("[APP-OWNERSHIP] pid=%d stage=termination-delegate", getpid())
        guard !terminationIsInProgress else {
            NSLog("[APP-OWNERSHIP] pid=%d stage=termination-already-pending", getpid())
            return .terminateLater
        }
        guard let terminationHandler else {
            NSLog("[APP-OWNERSHIP] pid=%d stage=termination-no-handler", getpid())
            return .terminateNow
        }

        terminationIsInProgress = true
        Task { @MainActor in
            NSLog("[APP-OWNERSHIP] pid=%d stage=shutdown-task-enter", getpid())
            await terminationHandler()
            NSLog("[APP-OWNERSHIP] pid=%d stage=shutdown-complete", getpid())
            NSLog("[APP-OWNERSHIP] pid=%d stage=termination-reply", getpid())
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        NSLog("[APP-OWNERSHIP] pid=%d stage=appkit-will-terminate", getpid())
    }
}

private struct BeakrMainWindowCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Show Beakr") {
                openWindow(id: "main")
            }
            .keyboardShortcut("0", modifiers: .command)
        }
    }
}
#endif


/// An advisory lock on a permanent inode. Never unlink this file on release:
/// another process could otherwise lock a different inode at the same path.
/// Compiled on iOS too so isolated tests can exercise the Darwin lock primitive.
nonisolated final class ApplicationStorageOwnership {
    enum Failure: Error, Equatable {
        case alreadyRunning
        case system(Int32)
    }

    private let descriptor: Int32
    private let rootURL: URL
    private let ownerToken = UUID()

    private struct Owner: Codable {
        let pid: Int32
        let token: UUID
    }
    private struct QuitRequest: Codable {
        let owner: UUID
        let createdAt: Date
    }

    init(rootURL: URL) throws {
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let url = rootURL.appendingPathComponent(".application-owner.lock")
        let fd = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        }
        guard fd >= 0 else { throw Failure.system(errno) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            Darwin.close(fd)
            if code == EWOULDBLOCK { throw Failure.alreadyRunning }
            throw Failure.system(code)
        }
        do {
            let owner = Owner(pid: getpid(), token: ownerToken)
            try JSONEncoder().encode(owner).write(to: rootURL.appendingPathComponent(".application-owner.json"), options: .atomic)
        } catch {
            Darwin.close(fd)
            throw error
        }
        descriptor = fd
        self.rootURL = rootURL
    }

    /// A notification is only a wake-up. The request itself must reside in the
    /// same application storage and target the current lock owner's launch token.
    static func requestNormalQuit(rootURL: URL, expectedPID: Int32, now: Date = Date()) throws -> UUID {
        let ownerURL = rootURL.appendingPathComponent(".application-owner.json")
        let bytes = try Data(contentsOf: ownerURL)
        guard bytes.count <= 4096 else { throw Failure.system(EINVAL) }
        let owner = try JSONDecoder().decode(Owner.self, from: bytes)
        guard owner.pid == expectedPID else { throw Failure.alreadyRunning }
        let request = QuitRequest(owner: owner.token, createdAt: now)
        try JSONEncoder().encode(request).write(to: requestURL(rootURL, token: owner.token), options: .atomic)
        return owner.token
    }

    func consumeQuitRequest(now: Date = Date()) -> Bool {
        let url = Self.requestURL(rootURL, token: ownerToken)
        guard let bytes = try? Data(contentsOf: url) else { return false }
        try? FileManager.default.removeItem(at: url)
        guard bytes.count <= 4096,
              let request = try? JSONDecoder().decode(QuitRequest.self, from: bytes),
              request.owner == ownerToken,
              now.timeIntervalSince(request.createdAt) >= 0,
              now.timeIntervalSince(request.createdAt) < 15 else { return false }
        return true
    }

    static func removeQuitRequest(rootURL: URL, token: UUID) {
        try? FileManager.default.removeItem(at: requestURL(rootURL, token: token))
    }

    private static func requestURL(_ root: URL, token: UUID) -> URL {
        root.appendingPathComponent(".replacement-request-\(token.uuidString).json")
    }

    deinit {
        // Closing the descriptor also releases ownership after a crash/exit.
        Darwin.close(descriptor)
    }
}

/// A handover requires both process termination and a new atomic lock acquisition.
/// Process discovery or an unlocked file alone is not sufficient.
nonisolated enum ApplicationOwnershipHandover {
    enum Outcome {
        case waiting
        case acquired(ApplicationStorageOwnership)
        case failed
    }

    static func poll(previousTerminated: Bool, timedOut: Bool, rootURL: URL) -> Outcome {
        guard !timedOut else { return .failed }
        guard previousTerminated else { return .waiting }
        do { return .acquired(try ApplicationStorageOwnership(rootURL: rootURL)) }
        catch ApplicationStorageOwnership.Failure.alreadyRunning { return .waiting }
        catch { return .failed }
    }
}

#if os(macOS)
@MainActor
private enum MacApplicationOwnership {
    // Retain ownership through all window closures, profile switches and shutdown work.
    private static var ownership: ApplicationStorageOwnership?
    private static var replacementObserver: MacReplacementObserver?
    static let replacementNotification = Notification.Name("net.beakr.application.requestNormalQuit")

    static func enableReplacementRequests() {
        guard replacementObserver == nil, ownership != nil else { return }
        let observer = MacReplacementObserver()
        replacementObserver = observer
        DistributedNotificationCenter.default().addObserver(observer,
            selector: #selector(MacReplacementObserver.receive(_:)), name: replacementNotification,
            object: nil, suspensionBehavior: .deliverImmediately)
        NSLog("[APP-OWNERSHIP] pid=%d stage=receiver-ready", getpid())
        handleReplacementRequest()
    }

    static func handleReplacementRequest() {
        guard ownership?.consumeQuitRequest() == true else {
            NSLog("[APP-OWNERSHIP] pid=%d stage=request-not-valid-or-absent", getpid())
            return
        }
        NSLog("[APP-OWNERSHIP] pid=%d stage=request-consumed-quit-self", getpid())
        // terminate() can enter AppKit's synchronous termination loop. Calling it
        // inside a Swift main-actor job prevents the delegate's async shutdown job
        // from running. Let this job return before entering AppKit from the run loop.
        RunLoop.main.perform(inModes: [.default]) {
            MainActor.assumeIsolated {
                NSLog("[APP-OWNERSHIP] pid=%d stage=quit-from-run-loop", getpid())
                NSApplication.shared.terminate(nil)
            }
        }
    }

    static func requireOwnership() {
        guard ownership == nil else { return }
        let current = NSRunningApplication.current
        let others = Bundle.main.bundleIdentifier.map { identifier in
            NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
                .filter { $0.processIdentifier != current.processIdentifier && !$0.isTerminated }
        } ?? []
        // Never choose an arbitrary process for replacement when discovery is ambiguous.
        let other = others.count == 1 ? others.first : nil
        var storageRoot: URL?
        do {
            let root = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true
            ).appendingPathComponent("Beakr", isDirectory: true)
            storageRoot = root
            ownership = try ApplicationStorageOwnership(rootURL: root)
        } catch {
            let duplicate = (error as? ApplicationStorageOwnership.Failure) == .alreadyRunning
            let alert = NSAlert()
            alert.messageText = duplicate
                ? String(localized: "Beakr is already running")
                : String(localized: "Beakr couldn’t open its storage")
            alert.informativeText = duplicate
                ? String(localized: "Use the running app, or ask it to quit normally so this version can start.")
                : String(localized: "Beakr could not secure exclusive access to its saved profiles. Quit and try again.")
            if duplicate, other != nil {
                alert.addButton(withTitle: String(localized: "Show Existing Beakr"))
            }
            alert.addButton(withTitle: String(localized: "Quit"))
            if duplicate, other != nil {
                alert.addButton(withTitle: String(localized: "Quit Running Beakr and Launch This Version"))
            }
            NSApplication.shared.activate()
            let response = alert.runModal()
            if duplicate, let other, response == .alertFirstButtonReturn {
                NSApplication.shared.yieldActivation(to: other)
                other.activate(options: [])
            }
            if duplicate, let other, let storageRoot, response == .alertThirdButtonReturn {
                if let acquired = MacOwnershipReplacement.acquire(afterQuitting: other, rootURL: storageRoot) {
                    ownership = acquired
                    return // Continue this selected executable's startup, still before model construction.
                }
            }
            // No application model, runtime, intent adapter or profile store has
            // been constructed. Exit only this rejected launch.
            exit(duplicate ? EXIT_SUCCESS : EXIT_FAILURE)
        }
    }
}

@MainActor
private final class MacReplacementObserver: NSObject {
    @objc nonisolated func receive(_ notification: Notification) {
        Task { @MainActor in
            NSLog("[APP-OWNERSHIP] pid=%d stage=notification-received", getpid())
            MacApplicationOwnership.handleReplacementRequest()
        }
    }
}

@MainActor
private final class MacOwnershipReplacement {
    private var acquired: ApplicationStorageOwnership?
    private var failed = false

    static func acquire(afterQuitting other: NSRunningApplication, rootURL: URL) -> ApplicationStorageOwnership? {
        let token: UUID?
        do {
            token = other.isTerminated ? nil : try ApplicationStorageOwnership.requestNormalQuit(
                rootURL: rootURL, expectedPID: other.processIdentifier)
        } catch {
            NSLog("[APP-OWNERSHIP] pid=%d target=%d stage=request-write-failed error=%@", getpid(), other.processIdentifier, String(describing: error))
            showFailure(String(localized: "The quit request could not be saved for the running instance. Quit it normally, then launch this version."))
            return nil
        }
        NSLog("[APP-OWNERSHIP] pid=%d target=%d stage=request-ready", getpid(), other.processIdentifier)
        defer {
            if let token { ApplicationStorageOwnership.removeQuitRequest(rootURL: rootURL, token: token) }
        }
        if token != nil {
            // App Sandbox permits distributed notifications with no userInfo.
            // Only the owner can validate and consume the storage-scoped request.
            DistributedNotificationCenter.default().postNotificationName(
                MacApplicationOwnership.replacementNotification, object: nil,
                userInfo: nil, deliverImmediately: true)
            NSLog("[APP-OWNERSHIP] pid=%d target=%d stage=notification-posted", getpid(), other.processIdentifier)
        }
        let replacement = MacOwnershipReplacement()
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        let waiting = NSAlert()
        waiting.messageText = String(localized: "Waiting for Beakr to quit")
        waiting.informativeText = String(localized: "The running app is saving and shutting down. This version will start when it finishes. Cancel closes this launch; it cannot undo the quit request already sent.")
        waiting.addButton(withTitle: String(localized: "Cancel This Launch"))
        // A modal-panel timer keeps the startup dialog responsive without constructing
        // a second application model or starting any networking while we wait.
        let timer = Timer(timeInterval: 0.1, repeats: true) { _ in
            MainActor.assumeIsolated {
                switch ApplicationOwnershipHandover.poll(previousTerminated: other.isTerminated,
                    timedOut: ContinuousClock.now >= deadline, rootURL: rootURL) {
                case .waiting: break
                case .acquired(let ownership):
                    replacement.acquired = ownership
                    NSLog("[APP-OWNERSHIP] pid=%d target=%d stage=handover-acquired", getpid(), other.processIdentifier)
                    NSApplication.shared.abortModal()
                case .failed:
                    replacement.failed = true
                    NSLog("[APP-OWNERSHIP] pid=%d target=%d stage=handover-failed terminated=%d timedOut=%d", getpid(), other.processIdentifier, other.isTerminated ? 1 : 0, ContinuousClock.now >= deadline ? 1 : 0)
                    NSApplication.shared.abortModal()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .modalPanel)
        _ = waiting.runModal()
        timer.invalidate()
        waiting.window.orderOut(nil)
        if let acquired = replacement.acquired { return acquired }
        if replacement.failed {
            showFailure(other.isTerminated
                ? String(localized: "The previous instance exited, but this version could not acquire its storage. Another instance may have started. Quit this launch and check the running apps.")
                : String(localized: "The running Beakr did not exit within 15 seconds. The request may not have reached it, or shutdown may still be in progress. No app was forced to quit."))
        }
        return nil
    }

    private static func showFailure(_ explanation: String) {
        let alert = NSAlert()
        alert.messageText = String(localized: "This version couldn’t start")
        alert.informativeText = explanation
        alert.addButton(withTitle: String(localized: "Quit This Launch"))
        alert.runModal()
    }
}

#endif
