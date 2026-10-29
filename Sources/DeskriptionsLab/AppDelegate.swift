import AppKit
import CoreGraphics
@preconcurrency import ScreenCaptureKit
import CoreMedia
import DeskriptionsCore

@main @MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, SCStreamOutput, SCStreamDelegate {
    private var statusItem: NSStatusItem!
    private var menu = NSMenu()
    private var stream: SCStream?
    private var preview: NSPanel?
    private var imageView: NSImageView?
    private let captureQueue = DispatchQueue(label: "org.deskriptions.capture")
    private let shortcutManager = ShortcutManager()
    private var windows: [SCWindow] = []
    private let desktopFlow = DesktopFlowController()
    private let setupController = SetupController()
    private lazy var settingsController = SettingsController(shortcuts: shortcutManager, actions: .init(chooseWindow: { [weak self] in self?.loadWindows() }, nativeInventory: { [weak self] in self?.printInventory() }, exportDiagnostics: { [weak self] in self?.desktopFlow.exportDiagnostics() }, recentStatus: { [weak self] in self?.desktopFlow.showRecentStatus() }))
    private var previewStallCheck: DispatchWorkItem?
    private var previewTitle = ""
    private var workspaceActivationObserver: NSObjectProtocol?
    private var workspaceTerminationObserver: NSObjectProtocol?
    private var displayObserver: NSObjectProtocol?
    private var lastExternalPID: pid_t?
    private struct PreviewSource {
        var windowID: CGWindowID
        let processID: pid_t
        let bundleIdentifier: String?
        let title: String
    }
    private var previewSource: PreviewSource?
    private var previewWatchdog: Timer?
    private var lastPreviewFrameAt: Date?
    private var previewCaptureStartedAt: Date?
    private var previewRecoveryAttempts = 0
    private var previewRecoveryTask: Task<Void, Never>?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // Command-line launch modes are used by the integration harness and need
        // a normal app activation so their modal UI cannot become an invisible
        // accessory-app dialog. The ordinary menu-bar launch remains accessory-only.
        let hasVisibleLaunchMode = CommandLine.arguments.contains("--save-desktop") || CommandLine.arguments.contains("--desktops") || CommandLine.arguments.contains("--setup") || CommandLine.arguments.contains("--settings") || CommandLine.arguments.contains("--settings-stress")
        app.setActivationPolicy(hasVisibleLaunchMode ? .regular : .accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = menuBarImage()
        statusItem.button?.imagePosition = .imageOnly
        statusItem.menu = menu
        menu.delegate = self
        shortcutManager.onAction = { [weak self] action in switch action { case .pin: self?.pinFocused(); case .save: self?.saveDesktop(); case .load: self?.openDesktops() } }
        if let error = shortcutManager.install() { showError(error) }
        installEditingMenu()
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceActivationObserver = workspaceCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            Task { @MainActor in self?.lastExternalPID = app.processIdentifier }
        }
        workspaceTerminationObserver = workspaceCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            Task { @MainActor [weak self] in
                guard let self, app.processIdentifier == self.previewSource?.processID else { return }
                self.preview?.title = "Source application closed"
                self.previewSource = nil
                self.previewRecoveryTask?.cancel(); self.previewRecoveryTask = nil
                let old = self.stream; self.stream = nil
                try? await old?.stopCapture()
            }
        }
        displayObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.schedulePreviewRecovery(reason: "display configuration changed", immediate: true) } }
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != ProcessInfo.processInfo.processIdentifier { lastExternalPID = front.processIdentifier }
        rebuildMenu()
        if let option = CommandLine.arguments.firstIndex(of: "--preview-document-check"), CommandLine.arguments.indices.contains(option + 1) {
            let path = CommandLine.arguments[option + 1]
            Task { @MainActor in
                let adapter = PreviewAdapter()
                let saved = SavedPreviewDocument(path: path, displayName: URL(fileURLWithPath: path).lastPathComponent)
                do {
                    _ = try await adapter.restore(saved)
                    let closed = try await adapter.close(saved)
                    print("Preview disposable document restore: \(closed ? "opened, verified, and closed exactly" : "opened and verified; exact close was not confirmed")")
                } catch {
                    print("Preview disposable document restore failed: \(error.localizedDescription)")
                }
                NSApp.terminate(nil)
            }
        }
        if CommandLine.arguments.contains("--preview-inventory-check") {
            Task { @MainActor in
                do {
                    let documents = try await PreviewAdapter().inventoryWithRetry()
                    print("Preview inventory: \(documents.count) exact document(s)")
                    for document in documents { print("- \(document.displayName) | \(document.onScreen ? "on screen" : "not on screen")") }
                } catch { print("Preview inventory failed: \(error.localizedDescription)") }
                NSApp.terminate(nil)
            }
        }
        if CommandLine.arguments.contains("--powerpoint-inventory-check") {
            Task { @MainActor in
                do {
                    let adapter = PowerPointAdapter()
                    let documents = try await adapter.inventoryWithRetry()
                    print("PowerPoint inventory: \(documents.count) exact presentation(s); unidentified: \(adapter.hasUnidentifiedPresentations)")
                    for document in documents { print("- \(document.displayName) | \(document.onScreen ? "on screen" : "not on screen")") }
                } catch { print("PowerPoint inventory failed: \(error.localizedDescription)") }
                NSApp.terminate(nil)
            }
        }
        if let option = CommandLine.arguments.firstIndex(of: "--powerpoint-document-check"), CommandLine.arguments.indices.contains(option + 1) {
            let path = CommandLine.arguments[option + 1]
            Task { @MainActor in
                let adapter = PowerPointAdapter()
                let applicationPath = NSWorkspace.shared.urlForApplication(withBundleIdentifier: PowerPointAdapter.bundleIdentifier)?.path
                let saved = SavedDocumentReference(applicationBundleID: PowerPointAdapter.bundleIdentifier, applicationBundlePath: applicationPath, path: path, displayName: URL(fileURLWithPath: path).lastPathComponent)
                do {
                    _ = try await DocumentRestorer().restore(saved, using: adapter)
                    print("PowerPoint disposable presentation restore: opened or reused and verified exactly")
                } catch { print("PowerPoint disposable presentation restore failed: \(error.localizedDescription)") }
                NSApp.terminate(nil)
            }
        }
        if CommandLine.arguments.contains("--pin-focused") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.pinFocused() }
        }
        if CommandLine.arguments.contains("--save-desktop") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.saveDesktop() }
        }
        if CommandLine.arguments.contains("--desktops") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.openDesktops() }
        }
        if CommandLine.arguments.contains("--setup") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.showSetup() }
        }
        if CommandLine.arguments.contains("--settings") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.showSettings() }
        }
        if CommandLine.arguments.contains("--settings-stress") {
            Task { @MainActor [weak self] in
                guard let self else { return }
                let passed = await settingsController.runLifecycleStress(cycles: 50)
                print("settings lifecycle stress (50 cycles): \(passed ? "passed" : "failed")")
                NSApp.terminate(passed ? nil : NSNumber(value: 1))
            }
        }
    }

    func menuWillOpen(_ menu: NSMenu) { rebuildMenu() }

    private func rebuildMenu() {
        menu.removeAllItems()
        let pin = NSMenuItem(title: menuTitle("Pin focused window", .pin), action: #selector(pinFocused), keyEquivalent: "")
        pin.target = self; menu.addItem(pin)
        menu.addItem(.separator())
        let save = NSMenuItem(title: menuTitle("Save Desktop…", .save), action: #selector(saveDesktop), keyEquivalent: "")
        save.target = self; menu.addItem(save)
        let saved = NSMenuItem(title: menuTitle("Load Desktop…", .load), action: #selector(openDesktops), keyEquivalent: "")
        saved.target = self; menu.addItem(saved)
        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ","); settings.target = self; menu.addItem(settings)
        let dismiss = NSMenuItem(title: "Dismiss preview", action: #selector(stopPreview), keyEquivalent: "")
        dismiss.target = self; dismiss.isEnabled = preview != nil; menu.addItem(dismiss)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }
    private func menuTitle(_ title: String, _ action: ShortcutManager.Action) -> String { let shortcut = shortcutManager.display(for: action); return shortcut.isEmpty ? title : "\(title)  \(shortcut)" }

    @objc private func saveDesktop() { desktopFlow.openSaveDesktop() }
    @objc private func openDesktops() { desktopFlow.openDesktops() }
    @objc private func showSetup() { settingsController.show(page: "Diagnostics") }
    @objc private func showSettings() { settingsController.show() }
    @objc func showSetupFromFlow() { settingsController.show(page: "Extensions") }
    func showSetupFromSettings() { setupController.show() }

    @objc private func loadWindows() {
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
                windows = content.windows.filter { $0.owningApplication?.bundleIdentifier != Bundle.main.bundleIdentifier && $0.windowLayer == 0 }
                await MainActor.run {
                    let picker = NSMenu()
                    for window in windows.prefix(100) {
                        let title = "\(window.owningApplication?.applicationName ?? "App") — \(window.title ?? "Untitled") [\(window.windowID)]"
                        let item = NSMenuItem(title: title, action: #selector(self.chooseWindow(_:)), keyEquivalent: "")
                        item.target = self; item.representedObject = NSNumber(value: window.windowID); picker.addItem(item)
                    }
                    self.statusItem.menu = picker
                    self.statusItem.button?.performClick(nil)
                    self.statusItem.menu = self.menu
                }
            } catch { showError("Window enumeration failed: \(error.localizedDescription)") }
        }
    }

    @objc private func chooseWindow(_ sender: NSMenuItem) {
        guard let id = (sender.representedObject as? NSNumber)?.uint32Value,
              let selected = windows.first(where: { $0.windowID == id }) else { return }
        Task { await startPreview(selected) }
    }

    @objc private func pinFocused() {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let selfPID = ProcessInfo.processInfo.processIdentifier
        let currentFront = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let frontPID = currentFront != selfPID ? currentFront : lastExternalPID
        let eligible: ([[String: Any]]) -> [[String: Any]] = { rows in rows.filter { ($0[kCGWindowLayer as String] as? Int) == 0 && ($0[kCGWindowOwnerPID as String] as? Int32) != selfPID && ($0[kCGWindowOwnerName as String] as? String) != "Window Server" } }
        let candidates = eligible(info)
        let row = candidates.first(where: { ($0[kCGWindowOwnerPID as String] as? Int32) == frontPID }) ?? candidates.first
        guard let row,
              let number = row[kCGWindowNumber as String] as? UInt32 else {
            showError("No focused capturable window found. Use Choose window for off-Space windows."); return
        }
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
                guard let selected = content.windows.first(where: { $0.windowID == number }) else { throw LabError.notShareable }
                await startPreview(selected)
            } catch {
                if !CGPreflightScreenCaptureAccess() {
                    // Do not request TCC access here: presenting the system consent
                    // sheet and an app-modal error at the same time hides the Allow
                    // button. The setup screen provides one explicit request action.
                    setupController.show()
                } else { showError("Capture permission is available, but the selected window could not be captured: \(error.localizedDescription)") }
            }
        }
    }

    @MainActor private func startPreview(_ window: SCWindow) async {
        stopPreview()
        let panel = NSPanel(contentRect: NSRect(x: 80, y: 80, width: 480, height: 300), styleMask: [.titled, .resizable, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Live: \(window.title ?? "Window")"
        previewTitle = panel.title
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isFloatingPanel = true; panel.hidesOnDeactivate = false; panel.becomesKeyOnlyIfNeeded = true
        let view = NSImageView(frame: panel.contentView?.bounds ?? .zero)
        view.imageScaling = .scaleProportionallyUpOrDown; view.autoresizingMask = [.width, .height]
        panel.contentView = view; panel.orderFrontRegardless()
        preview = panel; imageView = view
        previewSource = PreviewSource(windowID: window.windowID, processID: window.owningApplication?.processID ?? 0, bundleIdentifier: window.owningApplication?.bundleIdentifier, title: window.title ?? "")
        previewRecoveryAttempts = 0; lastPreviewFrameAt = nil
        do { try await startCapture(window) }
        catch { panel.close(); preview = nil; imageView = nil; previewSource = nil; showError("Capture start failed: \(error.localizedDescription)") }
    }

    @MainActor private func startCapture(_ window: SCWindow) async throws {
        let old = stream; stream = nil; try? await old?.stopCapture()
        let config = SCStreamConfiguration(), scale = NSScreen.main?.backingScaleFactor ?? 2
        let requestedWidth = max(1, Int(window.frame.width * scale)), requestedHeight = max(1, Int(window.frame.height * scale))
        let factor = min(1, min(2560 / Double(requestedWidth), 1440 / Double(requestedHeight)))
        config.width = max(1, Int(Double(requestedWidth) * factor)); config.height = max(1, Int(Double(requestedHeight) * factor))
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30); config.queueDepth = 5; config.showsCursor = true
        let capture = SCStream(filter: SCContentFilter(desktopIndependentWindow: window), configuration: config, delegate: self)
        try capture.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)
        stream = capture; try await capture.startCapture()
        lastPreviewFrameAt = Date(); previewCaptureStartedAt = Date(); installPreviewWatchdog()
    }

    @MainActor private func installPreviewWatchdog() {
        previewWatchdog?.invalidate()
        previewWatchdog = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.preview != nil, self.stream != nil, let last = self.lastPreviewFrameAt else { return }
                let now = Date()
                if now.timeIntervalSince(last) > 4 { self.schedulePreviewRecovery(reason: "frame delivery stalled") }
                else if self.previewRecoveryAttempts > 0, let started = self.previewCaptureStartedAt, now.timeIntervalSince(started) > 12 { self.previewRecoveryAttempts = 0 }
            }
        }
    }

    @MainActor private func schedulePreviewRecovery(reason: String, immediate: Bool = false) {
        guard preview != nil, previewRecoveryTask == nil else { return }
        guard previewRecoveryAttempts < 3 else { preview?.title = "Preview stalled — source may be minimized, protected, or suspended"; return }
        previewRecoveryAttempts += 1; preview?.title = "Recovering preview — \(reason)"
        let delay = immediate ? 0.0 : pow(2.0, Double(previewRecoveryAttempts - 1))
        previewRecoveryTask = Task { @MainActor [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled else { return }
            guard let self, let source = self.previewSource, self.preview != nil else { return }
            var needsRetry = false
            defer {
                self.previewRecoveryTask = nil
                if needsRetry { self.schedulePreviewRecovery(reason: reason) }
            }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
                let exact = content.windows.first { $0.windowID == source.windowID }
                let candidates = content.windows.filter { candidate in
                    candidate.owningApplication?.processID == source.processID && (source.title.isEmpty || candidate.title == source.title)
                }
                guard let window = exact ?? (candidates.count == 1 ? candidates[0] : nil) else {
                    self.preview?.title = candidates.count > 1 ? "Preview recovery needs an unambiguous source window" : "Source window is no longer available"
                    needsRetry = candidates.count <= 1
                    return
                }
                self.previewSource?.windowID = window.windowID
                try await self.startCapture(window)
            } catch { self.preview?.title = "Preview recovery failed — \(error.localizedDescription)"; needsRetry = true }
        }
    }

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid, let buffer = sampleBuffer.imageBuffer else { return }
        let producingStream = ObjectIdentifier(stream)
        let image = CIImage(cvPixelBuffer: buffer)
        let rep = NSCIImageRep(ciImage: image)
        let nsImage = NSImage(size: rep.size); nsImage.addRepresentation(rep)
        DispatchQueue.main.async { [weak self] in
            guard let self, let current = self.stream, ObjectIdentifier(current) == producingStream else { return }
            self.previewStallCheck?.cancel(); self.previewStallCheck = nil
            self.lastPreviewFrameAt = Date(); self.imageView?.image = nsImage
            self.preview?.title = self.previewTitle
        }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        let stoppedID = ObjectIdentifier(stream)
        DispatchQueue.main.async { [weak self] in guard let self, let current = self.stream, ObjectIdentifier(current) == stoppedID else { return }; self.stream = nil; self.schedulePreviewRecovery(reason: error.localizedDescription) }
    }

    @MainActor @objc private func stopPreview() {
        let old = stream; stream = nil
        previewStallCheck?.cancel(); previewStallCheck = nil
        previewWatchdog?.invalidate(); previewWatchdog = nil; previewRecoveryTask?.cancel(); previewRecoveryTask = nil; previewSource = nil; lastPreviewFrameAt = nil; previewCaptureStartedAt = nil; previewRecoveryAttempts = 0
        Task { try? await old?.stopCapture() }
        preview?.close(); preview = nil; imageView = nil
    }

    @objc private func printInventory() {
        let rows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let result = rows.compactMap { row -> NativeWindow? in
            guard let id = row[kCGWindowNumber as String] as? UInt32,
                  let pid = row[kCGWindowOwnerPID as String] as? Int32,
                  let owner = row[kCGWindowOwnerName as String] as? String,
                  let dict = row[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: dict as CFDictionary) else { return nil }
            return NativeWindow(windowID: id, ownerPID: pid, ownerName: owner, title: row[kCGWindowName as String] as? String ?? "", bounds: .init(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height), onScreen: row[kCGWindowIsOnscreen as String] as? Bool ?? false)
        }
        if let data = try? JSONEncoder.pretty.encode(result) { print(String(decoding: data, as: UTF8.self)) }
    }

    private func showError(_ text: String) { DispatchQueue.main.async { let alert = NSAlert(); alert.messageText = "Deskriptions"; alert.informativeText = text; alert.runModal() } }
    func applicationWillTerminate(_ notification: Notification) {
        if let workspaceActivationObserver { NSWorkspace.shared.notificationCenter.removeObserver(workspaceActivationObserver) }
        if let workspaceTerminationObserver { NSWorkspace.shared.notificationCenter.removeObserver(workspaceTerminationObserver) }
        if let displayObserver { NotificationCenter.default.removeObserver(displayObserver) }
        stopPreview()
    }

    private func installEditingMenu() {
        let main = NSMenu(); let appItem = NSMenuItem(); main.addItem(appItem); let appMenu = NSMenu(); appItem.submenu = appMenu; appMenu.addItem(NSMenuItem(title:"Quit Deskriptions", action:#selector(NSApplication.terminate(_:)), keyEquivalent:"q"))
        let editItem = NSMenuItem(); main.addItem(editItem); let edit = NSMenu(title:"Edit"); editItem.submenu = edit
        for (title, action, key) in [("Undo", Selector(("undo:")), "z"),("Redo", Selector(("redo:")), "Z"),("Cut", #selector(NSText.cut(_:)), "x"),("Copy", #selector(NSText.copy(_:)), "c"),("Paste", #selector(NSText.paste(_:)), "v"),("Select All", #selector(NSText.selectAll(_:)), "a")] { edit.addItem(NSMenuItem(title:title,action:action,keyEquivalent:key)) }
        NSApp.mainMenu = main
    }
    private func menuBarImage() -> NSImage {
        let image = NSImage(size:NSSize(width:20,height:18), flipped:false) { rect in
            let font = NSFont(name:"Snell Roundhand Bold",size:18) ?? NSFontManager.shared.convert(.systemFont(ofSize:17,weight:.semibold),toHaveTrait:.italicFontMask)
            let text = NSAttributedString(string:"D",attributes:[.font:font,.foregroundColor:NSColor.black]); let size=text.size(); text.draw(at:NSPoint(x:(rect.width-size.width)/2,y:(rect.height-size.height)/2-1)); return true
        }; image.isTemplate=true; return image
    }
}

enum LabError: LocalizedError { case notShareable; var errorDescription: String? { "Window is not in ScreenCaptureKit shareable content." } }
extension JSONEncoder { static var pretty: JSONEncoder { let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e } }

