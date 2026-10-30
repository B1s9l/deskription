import AppKit
import ApplicationServices
import CoreGraphics
import DeskriptionsCore

@main @MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var menu = NSMenu()
    private let shortcutManager = ShortcutManager()
    private let desktopFlow = DesktopFlowController()
    private let setupController = SetupController()
    private lazy var settingsController = SettingsController(shortcuts: shortcutManager, actions: .init(nativeInventory: { [weak self] in self?.printInventory() }, exportDiagnostics: { [weak self] in self?.desktopFlow.exportDiagnostics() }, recentStatus: { [weak self] in self?.desktopFlow.showRecentStatus() }))

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
        shortcutManager.onAction = { [weak self] action in switch action { case .save: self?.saveDesktop(); case .load: self?.openDesktops() } }
        if let error = shortcutManager.install() { showError(error) }
        installEditingMenu()
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
        if CommandLine.arguments.contains("--powerpoint-ax-check") {
            Task { @MainActor in
                let result = PowerPointAdapter().accessibilityInventoryForDiagnostics()
                print("PowerPoint AX inventory: trusted=\(AXIsProcessTrusted()) windows=\(result.windowCount) exact=\(result.documents.count)")
                for document in result.documents { print("- \(document.displayName)") }
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
                    let result = try await DocumentRestorer().restore(saved, using: adapter)
                    print(result.verification == .verifiedExact ? "PowerPoint disposable presentation restore: opened or reused and verified exactly" : "PowerPoint disposable presentation restore: open command accepted; exact verification unavailable")
                } catch { print("PowerPoint disposable presentation restore failed: \(error.localizedDescription)") }
                NSApp.terminate(nil)
            }
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
        let save = NSMenuItem(title: menuTitle("Save Desktop…", .save), action: #selector(saveDesktop), keyEquivalent: "")
        save.target = self; menu.addItem(save)
        let saved = NSMenuItem(title: menuTitle("Load Desktop…", .load), action: #selector(openDesktops), keyEquivalent: "")
        saved.target = self; menu.addItem(saved)
        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ","); settings.target = self; menu.addItem(settings)
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

extension JSONEncoder { static var pretty: JSONEncoder { let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e } }

