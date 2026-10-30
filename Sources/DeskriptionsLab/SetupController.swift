import AppKit
import ApplicationServices
import DeskriptionsCore

@MainActor final class SetupController: NSObject {
    private let bridge = FileAdapterBridge()
    private var panel: NSPanel?
    private var statusLabel: NSTextField?

    func show() {
        if let panel { panel.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); refresh(); return }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 650, height: 430), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = "Deskriptions Setup & Status"
        let status = NSTextField(wrappingLabelWithString: "Checking…"); status.frame = NSRect(x: 24, y: 70, width: 602, height: 330); status.font = .monospacedSystemFont(ofSize: 12, weight: .regular); statusLabel = status; panel.contentView?.addSubview(status)
        let install = NSButton(title: "Install / Repair Browser Bridges", target: self, action: #selector(installBridge)); install.frame = NSRect(x: 24, y: 20, width: 222, height: 32); panel.contentView?.addSubview(install)
        let access = NSButton(title: "Request Accessibility", target: self, action: #selector(requestAccessibility)); access.frame = NSRect(x: 256, y: 20, width: 170, height: 32); panel.contentView?.addSubview(access)
        let retry = NSButton(title: "Recheck", target: self, action: #selector(refresh)); retry.frame = NSRect(x: 526, y: 20, width: 100, height: 32); panel.contentView?.addSubview(retry)
        panel.center(); panel.makeKeyAndOrderFront(nil); self.panel = panel; NSApp.activate(ignoringOtherApps: true); refresh()
    }

    @objc func refresh() {
        statusLabel?.stringValue = "Checking current permission and connection state…"
        Task {
            let profiles = await bridge.connectedProfiles(), issues = await bridge.connectionIssueCounts()
            let accessibility = AXIsProcessTrusted() ? "WORKING — exact document identities available" : "OPTIONAL — needed for exact Preview identity and targeted PowerPoint verification"
            let connection = !profiles.isEmpty ? "WORKING — \(profiles.count) live profile connection(s)" : issues.incompatible > 0 ? "DENIED — incompatible adapter protocol observed" : issues.malformed > 0 ? "DENIED — malformed adapter registration observed" : "DISCONNECTED — reload the extension after installing its bridge"
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
            let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "development"
            let extensionVersions = Set(profiles.compactMap(\.adapterVersion)).sorted().joined(separator: ", ")
            statusLabel?.stringValue = """
            Accessibility:        \(accessibility)
            Automation:           requested on use for Finder, Notes, and Microsoft Office
            Screen Recording:     NOT USED
            Browser extension:    \(connection)

            App:                   \(version) (build \(build))
            App executable:        \(Bundle.main.executablePath ?? "unknown")
            Embedded bridge:       \(self.embeddedBridgeURL()?.path ?? "missing")
            Bridge registration:   \(self.bridgeManifestStatus())
            Extension version:     \(extensionVersions.isEmpty ? "not checked — no compatible live connection" : extensionVersions)
            Adapter protocol:      app v\(protocolVersion); incompatible observations: \(issues.incompatible)

            Accessibility is used only for exact document identity and verification. Finder, Notes, PowerPoint, Word, and Excel request application-specific Automation only when needed. Deskriptions no longer captures or streams windows and does not request Screen Recording access.
            """
        }
    }

    @objc private func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        statusLabel?.stringValue = "Accessibility: WAITING — approve Deskriptions, then choose Recheck."
        if !AXIsProcessTrusted(), let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(url) }
    }

    @objc private func installBridge() {
        do {
            for browser in ChromiumBrowser.allCases {
                guard let host = embeddedBridgeURL(for: browser), FileManager.default.isExecutableFile(atPath: host.path) else { throw SetupError.missingBridge }
                let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(browser.nativeMessagingDirectory, isDirectory: true)
                try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
                let manifest = base.appendingPathComponent("com.deskriptions.bridge.json")
                let object: [String: Any] = ["name":"com.deskriptions.bridge", "description":"Local \(browser.displayName) bridge for Deskriptions", "path":host.path, "type":"stdio", "allowed_origins":["chrome-extension://agimibdhlfgliioagkdaefkddfenhmfe/"]]
                try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]).write(to: manifest, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifest.path)
            }
            result("Browser bridges installed", "Reload the Deskriptions extension in each installed browser, then choose Recheck.")
        } catch { result("Browser bridge installation failed", error.localizedDescription) }
        refresh()
    }

    private func embeddedBridgeURL() -> URL? { Bundle.main.resourceURL?.appendingPathComponent("deskriptions-bridge") }
    private func embeddedBridgeURL(for browser: ChromiumBrowser) -> URL? { Bundle.main.resourceURL?.appendingPathComponent("deskriptions-bridge-\(browser.hostTag)") }
    private func bridgeManifestStatus() -> String { ChromiumBrowser.allCases.map { browser in
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(browser.nativeMessagingDirectory).appendingPathComponent("com.deskriptions.bridge.json")
        guard let data = try? Data(contentsOf: url), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let path = object["path"] as? String else { return "\(browser.displayName): MISSING" }
        guard FileManager.default.isExecutableFile(atPath: path) else { return "\(browser.displayName): BROKEN" }
        return path == embeddedBridgeURL(for: browser)?.path ? "\(browser.displayName): WORKING" : "\(browser.displayName): STALE"
    }.joined(separator: "; ") }
    private func result(_ title: String, _ text: String) { let alert = NSAlert(); alert.messageText = title; alert.informativeText = text; alert.runModal() }
    private enum SetupError: LocalizedError { case missingBridge; var errorDescription: String? { "This app copy does not contain an executable browser bridge." } }
}
