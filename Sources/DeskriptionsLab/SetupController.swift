import AppKit
import ApplicationServices
import CoreGraphics
import DeskriptionsCore
import ScreenCaptureKit

@MainActor
final class SetupController: NSObject {
    private let bridge = FileAdapterBridge()
    private var panel: NSPanel?
    private var statusLabel: NSTextField?

    func show() {
        if let panel { panel.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); refresh(); return }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 650, height: 470), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = "Deskriptions Setup & Status"
        let status = NSTextField(wrappingLabelWithString: "Checking…"); status.frame = NSRect(x: 24, y: 115, width: 602, height: 325); status.font = .monospacedSystemFont(ofSize: 12, weight: .regular); statusLabel = status; panel.contentView?.addSubview(status)
        let request = NSButton(title: "Request Capture Access", target: self, action: #selector(requestCapture)); request.frame = NSRect(x: 24, y: 65, width: 180, height: 32); panel.contentView?.addSubview(request)
        let settings = NSButton(title: "Open Capture Settings", target: self, action: #selector(openCaptureSettings)); settings.frame = NSRect(x: 214, y: 65, width: 180, height: 32); panel.contentView?.addSubview(settings)
        let install = NSButton(title: "Install / Repair Browser Bridges", target: self, action: #selector(installBridge)); install.frame = NSRect(x: 404, y: 65, width: 222, height: 32); panel.contentView?.addSubview(install)
        let previewAccess = NSButton(title: "Request Preview Access", target: self, action: #selector(requestAccessibility)); previewAccess.frame = NSRect(x: 24, y: 20, width: 180, height: 32); panel.contentView?.addSubview(previewAccess)
        let accessibilitySettings = NSButton(title: "Open Accessibility Settings", target: self, action: #selector(openAccessibilitySettings)); accessibilitySettings.frame = NSRect(x: 214, y: 20, width: 200, height: 32); panel.contentView?.addSubview(accessibilitySettings)
        let notesAccess = NSButton(title: "Request Notes Access", target: self, action: #selector(requestNotesAccess)); notesAccess.frame = NSRect(x: 424, y: 20, width: 155, height: 32); panel.contentView?.addSubview(notesAccess)
        let retry = NSButton(title: "Recheck", target: self, action: #selector(refresh)); retry.frame = NSRect(x: 526, y: 20, width: 100, height: 32); panel.contentView?.addSubview(retry)
        panel.center(); panel.makeKeyAndOrderFront(nil); self.panel = panel; NSApp.activate(ignoringOtherApps: true); refresh()
    }

    @objc func refresh() {
        statusLabel?.stringValue = "Checking current permission and connection state…"
        Task {
            async let captureCheck = CaptureAccessProbe.run()
            let profiles = await bridge.connectedProfiles(), issues = await bridge.connectionIssueCounts()
            let capture = await captureCheck
            let accessibility = AXIsProcessTrusted() ? "WORKING — Preview exact-document integration available" : "OPTIONAL — required only for Preview exact-document integration"
            let automation = "NOT CHECKED — Finder folders and selected Apple Notes perform functional checks on use"
            let connection: String
            if !profiles.isEmpty { connection = "WORKING — \(profiles.count) live profile connection(s)" }
            else if issues.incompatible > 0 { connection = "DENIED — incompatible adapter protocol observed" }
            else if issues.malformed > 0 { connection = "DENIED — malformed adapter registration observed" }
            else { connection = "DISCONNECTED — reload the extension after installing the matching bridge" }
            let store = try? DesktopStore.applicationSupport(), saved = store?.list().desktops ?? []
            let associated = profiles.filter { profile in saved.contains { desktop in desktop.profiles.contains { $0.installationID == profile.installationID && $0.applicationBundleID == profile.browser && $0.browserIdentityVerified && $0.launchUserDataDirectory != nil && $0.launchProfileDirectory != nil } } }.count
            let association = profiles.isEmpty ? "NOT CHECKED — no live browser profile; saved identities are preserved" : "\(associated)/\(profiles.count) connected profiles have a verified cold-launch mapping"
            let manifestStatus = self.bridgeManifestStatus()
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
            let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "development"
            let extensionVersions = Set(profiles.compactMap(\.adapterVersion)).sorted().joined(separator: ", ")
            let text = """
            Capture access:       \(capture.summary)
            Accessibility:        \(accessibility)
            Automation:           \(automation)
            Browser extension:    \(connection)
            Profile association:  \(association)

            App:                   \(version) (build \(build))
            App executable:        \(Bundle.main.executablePath ?? "unknown")
            Embedded bridge:       \(self.embeddedBridgeURL()?.path ?? "missing")
            Bridge registration:   \(manifestStatus)
            Extension version:     \(extensionVersions.isEmpty ? "not checked — no compatible live connection" : extensionVersions)
            Adapter protocol:      app v\(protocolVersion); incompatible observations: \(issues.incompatible)

            Capture permission is required only for live previews. Status above includes a real ScreenCaptureKit screenshot probe, not only the settings toggle. Accessibility is optional and used only when Preview exposes exact document URLs. Finder and Notes request application-specific Automation access on first use and report denial without saving or closing anything. Apple documents that a relaunch can be required after first granting capture access.
            """
            self.statusLabel?.stringValue = text
        }
    }

    @objc private func requestCapture() {
        statusLabel?.stringValue = "Capture access: WAITING — respond to the macOS permission prompt."
        // TCC consent UI must be requested by the foreground app on its main
        // thread. Dispatching this call to a worker can return a denial without
        // ever presenting the system sheet.
        let granted = CGRequestScreenCaptureAccess()
        if granted {
            statusLabel?.stringValue = "Capture access: GRANTED — checking functional ScreenCaptureKit capture…"
        } else {
            statusLabel?.stringValue = "Capture access: DENIED — use Open Capture Settings, then quit and reopen Deskriptions if macOS requests it."
        }
        refresh()
    }

    @objc private func openCaptureSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        statusLabel?.stringValue = "Preview access: WAITING — enable Deskriptions in Accessibility, then choose Recheck. A relaunch may be required."
    }

    @objc private func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func requestNotesAccess() {
        statusLabel?.stringValue = "Notes Automation: WAITING — respond to the macOS permission prompt."
        Task {
            do {
                try await NotesAdapter().requestAutomationPermission()
                statusLabel?.stringValue = "Notes Automation: WORKING — selected-note identity is available."
            } catch {
                statusLabel?.stringValue = "Notes Automation: DENIED OR UNAVAILABLE — \(error.localizedDescription)"
            }
        }
    }

    @objc private func installBridge() {
        do {
            for browser in ChromiumBrowser.allCases {
                guard let host = embeddedBridgeURL(for: browser), FileManager.default.isExecutableFile(atPath: host.path) else { throw SetupError.missingBridge }
                let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(browser.nativeMessagingDirectory, isDirectory: true)
                try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
                let manifest = base.appendingPathComponent("com.deskriptions.bridge.json")
                let object: [String: Any] = ["name":"com.deskriptions.bridge", "description":"Local \(browser.displayName) bridge for Deskriptions", "path":host.path, "type":"stdio", "allowed_origins":["chrome-extension://agimibdhlfgliioagkdaefkddfenhmfe/"]]
                let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
                try data.write(to: manifest, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifest.path)
            }
            showResult("Browser bridges installed", "Reload the Deskriptions extension in each installed Chromium browser, then choose Recheck. Existing saved Desktops were not changed.")
        } catch { showResult("Browser bridge installation failed", error.localizedDescription) }
        refresh()
    }

    private func embeddedBridgeURL() -> URL? { Bundle.main.resourceURL?.appendingPathComponent("deskriptions-bridge") }
    private func embeddedBridgeURL(for browser: ChromiumBrowser) -> URL? { Bundle.main.resourceURL?.appendingPathComponent("deskriptions-bridge-\(browser.hostTag)") }
    private func bridgeManifestStatus() -> String {
        return ChromiumBrowser.allCases.map { browser in
            let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(browser.nativeMessagingDirectory).appendingPathComponent("com.deskriptions.bridge.json")
            guard let data = try? Data(contentsOf: url), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let path = object["path"] as? String else { return "\(browser.displayName): MISSING" }
            guard FileManager.default.isExecutableFile(atPath: path) else { return "\(browser.displayName): BROKEN" }
            return path == embeddedBridgeURL(for: browser)?.path ? "\(browser.displayName): WORKING" : "\(browser.displayName): STALE"
        }.joined(separator: "; ")
    }
    private func showResult(_ title: String, _ text: String) { let alert = NSAlert(); alert.messageText = title; alert.informativeText = text; alert.runModal() }
    private enum SetupError: LocalizedError { case missingBridge; var errorDescription: String? { "This app copy does not contain an executable Chrome bridge. Install the freshly packaged Deskriptions.app." } }
}

private struct CaptureAccessResult: Sendable {
    let summary: String
}

private enum CaptureAccessProbe {
    static func run() async -> CaptureAccessResult {
        let preflight = CGPreflightScreenCaptureAccess()
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            let selfBundle = Bundle.main.bundleIdentifier
            guard let window = content.windows.first(where: {
                $0.windowLayer == 0 && $0.frame.width >= 80 && $0.frame.height >= 60 && $0.owningApplication?.bundleIdentifier != selfBundle
            }) else {
                return .init(summary: "AVAILABLE — ScreenCaptureKit enumeration succeeded; no external window is available for a frame probe")
            }
            let configuration = SCStreamConfiguration(); configuration.width = 32; configuration.height = 32; configuration.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: configuration)
            guard image.width > 0, image.height > 0 else { return .init(summary: "FAILED — ScreenCaptureKit returned an empty image") }
            return .init(summary: preflight ? "WORKING — functional ScreenCaptureKit frame captured" : "WORKING — functional frame captured although the legacy preflight flag is stale")
        } catch {
            let prefix = preflight ? "FAILED — permission preflight passed, but functional capture failed" : "DENIED OR RESTART REQUIRED — functional capture failed"
            return .init(summary: "\(prefix): \(error.localizedDescription)")
        }
    }
}
