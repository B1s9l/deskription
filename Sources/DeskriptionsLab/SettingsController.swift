import AppKit
import Carbon.HIToolbox
import CoreGraphics
import DeskriptionsCore
import ServiceManagement

enum ProfileConfigurationStore {
    private static let key = "browserProfilePaths.v1"
    static func all() -> [String: String] { UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:] }
    static func path(browser: String, installationID: String) -> String? { all()["\(browser)|\(installationID)"] }
    static func set(_ path: String?, browser: String, installationID: String) {
        var values = all(), identity = "\(browser)|\(installationID)"
        if let path, !path.isEmpty { values[identity] = path } else { values.removeValue(forKey: identity) }
        UserDefaults.standard.set(values, forKey: key)
    }
}

@MainActor
final class SettingsController: NSObject, NSWindowDelegate, NSTabViewDelegate {
    struct Actions {
        let nativeInventory: () -> Void, exportDiagnostics: () -> Void, recentStatus: () -> Void
    }
    private let bridge = FileAdapterBridge()
    private let shortcuts: ShortcutManager
    private let actions: Actions
    private var window: NSWindow?
    private var tabs: NSTabView!
    private var shortcutLabels: [ShortcutManager.Action: NSTextField] = [:]
    private var extensionStack: NSStackView?
    private weak var extensionDocumentView: NSView?
    private var extensionRefreshTask: Task<Void, Never>?
    private var extensionRefreshGeneration = 0
    private var diagnosticsLabel: NSTextField?
    private var loginStatus: NSTextField?
    private var savedDesktopCountLabel: NSTextField?
    private var autoDeleteToggle: NSButton?
    private var retentionSlider: NSSlider?
    private var retentionValueLabel: NSTextField?
    private var recordMonitor: Any?
    private let afterSavePreferences = AfterSavePreferenceStore()
    private let retentionPreferences = DesktopRetentionPreferences()
    private let desktopStore = try? DesktopStore.applicationSupport()
    private var lastRefreshAt = Date.distantPast
    private var lastRefreshPage: String?
    private var integrationIconCache: [String: NSImage] = [:]

    init(shortcuts: ShortcutManager, actions: Actions) { self.shortcuts = shortcuts; self.actions = actions }

    func show(page: String? = nil) {
        if window == nil { build() }
        if let page, let item = tabs.tabViewItems.first(where: { $0.label == page }) { tabs.selectTabViewItem(item) }
        refreshAll()
        window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }

    private func build() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 570), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        // Programmatically-created NSWindows may release themselves when closed.
        // This controller intentionally reuses one Settings window, so allowing
        // AppKit to release it leaves the Swift reference pointing at freed ObjC
        // storage. Keep ownership here and hide the window on Close instead.
        window.isReleasedWhenClosed = false
        window.title = "Deskriptions Settings"; window.minSize = NSSize(width: 680, height: 500); window.center(); window.delegate = self
        self.window = window
        let tabs = NSTabView(frame: NSRect(x: 16, y: 16, width: 728, height: 538)); tabs.autoresizingMask = [.width, .height]; tabs.delegate = self; window.contentView?.addSubview(tabs); self.tabs = tabs
        addTab("General", view: generalView()); addTab("Keyboard Shortcuts", view: shortcutsView()); addTab("Extensions", view: extensionsView()); addTab("Diagnostics", view: diagnosticsView()); addTab("Credits", view: creditsView())
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard Date().timeIntervalSince(lastRefreshAt) > 0.75 else { return }
        refreshAll()
    }

    private func refreshAll() {
        let selected = tabs?.selectedTabViewItem?.label
        guard selected != lastRefreshPage || Date().timeIntervalSince(lastRefreshAt) > 0.75 else { return }
        lastRefreshAt = Date(); lastRefreshPage = selected
        if selected == "Extensions" { refreshExtensions() }
        if selected == "Diagnostics" { refreshDiagnostics() }
        if selected == "General" { refreshLoginStatus(); refreshDesktopManagement() }
    }

    func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) { refreshAll() }

    func runLifecycleStress(cycles: Int) async -> Bool {
        show()
        guard let expectedWindow = window else { return false }
        for index in 0..<cycles {
            let page = tabs.tabViewItems[index % tabs.numberOfTabViewItems].label
            show(page: page)
            guard window === expectedWindow else { return false }
            expectedWindow.performClose(nil)
            guard window === expectedWindow, !expectedWindow.isVisible else { return false }
            try? await Task.sleep(for: .milliseconds(15))
        }
        show()
        return window === expectedWindow && expectedWindow.isVisible
    }
    private func addTab(_ label: String, view: NSView) { let item = NSTabViewItem(identifier: label); item.label = label; item.view = view; tabs.addTabViewItem(item) }
    private func page() -> NSView { NSView(frame: NSRect(x: 0, y: 0, width: 710, height: 500)) }
    private func heading(_ text: String, y: CGFloat, in view: NSView) { let label = NSTextField(labelWithString: text); label.font = .systemFont(ofSize: 18, weight: .semibold); label.frame = NSRect(x: 24, y: y, width: 640, height: 26); view.addSubview(label) }

    private func generalView() -> NSView {
        let v = page(); heading("General", y: 445, in: v)
        let title = NSTextField(labelWithString: "Default Save Desktop selection:"); title.frame = NSRect(x: 24, y: 390, width: 230, height: 24); v.addSubview(title)
        let popup = NSPopUpButton(frame: NSRect(x: 255, y: 386, width: 220, height: 30)); popup.addItems(withTitles: ["Visible windows", "All supported windows"]); popup.selectItem(at: UserDefaults.standard.bool(forKey: "initialSelectionAll") ? 1 : 0); popup.target = self; popup.action = #selector(selectionChanged(_:)); v.addSubview(popup)
        let afterTitle = NSTextField(labelWithString: "After saving a Desktop:"); afterTitle.frame = NSRect(x: 24, y: 330, width: 230, height: 24); v.addSubview(afterTitle)
        let afterPopup = NSPopUpButton(frame: NSRect(x: 255, y: 326, width: 220, height: 30)); afterPopup.addItems(withTitles: AfterSaveBehavior.allCases.map(\.title)); let existing = ((try? DesktopStore.applicationSupport())?.list().desktops.isEmpty == false); let selected = afterSavePreferences.behavior(hasExistingDesktops: existing); afterPopup.selectItem(at: AfterSaveBehavior.allCases.firstIndex(of: selected) ?? 2); afterPopup.target = self; afterPopup.action = #selector(afterSaveChanged(_:)); afterPopup.setAccessibilityLabel("After saving a Desktop"); v.addSubview(afterPopup)
        let afterHelp = NSTextField(wrappingLabelWithString: "Keep selected content open, safely close content supported by an integration, or choose after each successful save."); afterHelp.frame = NSRect(x: 255, y: 290, width: 410, height: 32); afterHelp.textColor = .secondaryLabelColor; v.addSubview(afterHelp)
        let login = NSButton(checkboxWithTitle: "Launch at login", target: self, action: #selector(toggleLogin(_:))); login.frame = NSRect(x: 24, y: 240, width: 200, height: 24); login.state = SMAppService.mainApp.status == .enabled ? .on : .off; v.addSubview(login)
        let status = NSTextField(wrappingLabelWithString: ""); status.frame = NSRect(x: 44, y: 200, width: 610, height: 38); status.textColor = .secondaryLabelColor; v.addSubview(status); loginStatus = status

        let management = NSTextField(labelWithString: "Saved Desktops"); management.font = .systemFont(ofSize: 13, weight: .semibold); management.frame = NSRect(x: 24, y: 169, width: 180, height: 22); v.addSubview(management)
        let count = NSTextField(labelWithString: ""); count.textColor = .secondaryLabelColor; count.frame = NSRect(x: 155, y: 169, width: 200, height: 22); v.addSubview(count); savedDesktopCountLabel = count
        let auto = NSButton(checkboxWithTitle: "Auto delete old saved Desktops", target: self, action: #selector(toggleAutoDelete(_:))); auto.frame = NSRect(x: 24, y: 134, width: 250, height: 24); auto.state = retentionPreferences.isEnabled ? .on : .off; v.addSubview(auto); autoDeleteToggle = auto
        let slider = NSSlider(value: Double(retentionPreferences.limit), minValue: Double(DesktopRetentionPreferences.allowedLimits.lowerBound), maxValue: Double(DesktopRetentionPreferences.allowedLimits.upperBound), target: self, action: #selector(retentionSliderChanged(_:))); slider.numberOfTickMarks = 0; slider.allowsTickMarkValuesOnly = false; slider.frame = NSRect(x: 44, y: 94, width: 315, height: 24); v.addSubview(slider); retentionSlider = slider
        let limit = NSTextField(labelWithString: "Keep newest \(retentionPreferences.limit)"); limit.frame = NSRect(x: 370, y: 94, width: 120, height: 24); v.addSubview(limit); retentionValueLabel = limit
        let saveLimit = NSButton(title: "Save limit", target: self, action: #selector(saveRetentionLimit)); saveLimit.frame = NSRect(x: 495, y: 89, width: 100, height: 30); v.addSubview(saveLimit)
        let deleteAll = NSButton(title: "Delete All Saved Desktops…", target: self, action: #selector(deleteAllSavedDesktops)); deleteAll.frame = NSRect(x: 24, y: 43, width: 220, height: 32); deleteAll.hasDestructiveAction = true; v.addSubview(deleteAll)
        let deletionHelp = NSTextField(labelWithString: "Deletes saved records only; applications, tabs, folders, settings, and the naming counter are unchanged."); deletionHelp.textColor = .secondaryLabelColor; deletionHelp.frame = NSRect(x: 255, y: 49, width: 430, height: 20); v.addSubview(deletionHelp)
        return v
    }
    @objc private func selectionChanged(_ sender: NSPopUpButton) { UserDefaults.standard.set(sender.indexOfSelectedItem == 1, forKey: "initialSelectionAll") }
    @objc private func afterSaveChanged(_ sender: NSPopUpButton) {
        guard AfterSaveBehavior.allCases.indices.contains(sender.indexOfSelectedItem) else { return }
        afterSavePreferences.set(AfterSaveBehavior.allCases[sender.indexOfSelectedItem])
    }
    @objc private func toggleLogin(_ sender: NSButton) {
        do { if sender.state == .on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
        catch { sender.state = SMAppService.mainApp.status == .enabled ? .on : .off; loginStatus?.stringValue = "Could not change login registration: \(error.localizedDescription)" }
        refreshLoginStatus()
    }
    private func refreshLoginStatus() {
        let text: String
        switch SMAppService.mainApp.status { case .enabled: text = "Working — Deskriptions will launch quietly in the menu bar."; case .requiresApproval: text = "Waiting for approval in System Settings → General → Login Items."; case .notRegistered: text = "Off — Deskriptions will not launch at login."; case .notFound: text = "Unavailable — install Deskriptions in /Applications before enabling."; @unknown default: text = "Status could not be determined." }
        loginStatus?.stringValue = text
    }

    private func refreshDesktopManagement() {
        let count = desktopStore?.list().desktops.count ?? 0
        savedDesktopCountLabel?.stringValue = "\(count) saved"
        autoDeleteToggle?.state = retentionPreferences.isEnabled ? .on : .off
        retentionSlider?.doubleValue = Double(retentionPreferences.limit)
        retentionValueLabel?.stringValue = "Keep newest \(retentionPreferences.limit)"
    }

    @objc private func toggleAutoDelete(_ sender: NSButton) {
        guard sender.state == .on else { retentionPreferences.setEnabled(false); return }
        let first = NSAlert(); first.messageText = "Enable automatic deletion?"; first.informativeText = "Older saved Desktops may be permanently deleted. The retention limit will apply to future successful saves."; first.addButton(withTitle: "Continue"); first.addButton(withTitle: "Cancel")
        guard first.runModal() == .alertFirstButtonReturn else { sender.state = .off; return }
        let count = desktopStore?.list().desktops.count ?? 0, limit = retentionPreferences.limit, removal = max(0, count - limit)
        let second = NSAlert(); second.messageText = "Confirm automatic deletion"; second.informativeText = "Keep only the newest \(limit) saved Desktops? \(removal) existing saved Desktop(s) will be deleted now. This does not close or delete original content."; second.addButton(withTitle: "Enable Auto Delete"); second.buttons.first?.hasDestructiveAction = removal > 0; second.addButton(withTitle: "Cancel")
        guard second.runModal() == .alertFirstButtonReturn else { sender.state = .off; return }
        retentionPreferences.setEnabled(true)
        applyCurrentRetention()
    }

    @objc private func retentionSliderChanged(_ sender: NSSlider) {
        let draft = Int(sender.doubleValue.rounded())
        sender.doubleValue = Double(draft)
        retentionValueLabel?.stringValue = "Keep newest \(draft)"
    }

    @objc private func saveRetentionLimit() {
        let draft = Int((retentionSlider?.doubleValue ?? Double(retentionPreferences.limit)).rounded())
        guard draft != retentionPreferences.limit else { return }
        let first = NSAlert(); first.messageText = "Change the saved Desktop limit?"; first.informativeText = "The limit is not changed until you complete both confirmations."; first.addButton(withTitle: "Continue"); first.addButton(withTitle: "Cancel")
        guard first.runModal() == .alertFirstButtonReturn else { refreshDesktopManagement(); return }
        let count = desktopStore?.list().desktops.count ?? 0, removal = retentionPreferences.isEnabled ? max(0, count - draft) : 0
        let effect = retentionPreferences.isEnabled
            ? "Only the newest \(draft) saved Desktops will be kept. \(removal) existing saved Desktop(s) will be deleted immediately."
            : "Automatic deletion is off, so no saved Desktops will be deleted unless it is enabled later."
        let second = NSAlert(); second.messageText = "Confirm new retention limit"; second.informativeText = "The new limit is \(draft). \(effect)"; second.addButton(withTitle: "Save Limit"); second.buttons.first?.hasDestructiveAction = removal > 0; second.addButton(withTitle: "Cancel")
        guard second.runModal() == .alertFirstButtonReturn else { refreshDesktopManagement(); return }
        retentionPreferences.setLimit(draft)
        if retentionPreferences.isEnabled { applyCurrentRetention() } else { refreshDesktopManagement() }
    }

    private func applyCurrentRetention() {
        guard let desktopStore else { show("The saved Desktop store is unavailable; no records were deleted."); refreshDesktopManagement(); return }
        let result = desktopStore.applyRetention(limit: retentionPreferences.limit)
        refreshDesktopManagement()
        if !result.failures.isEmpty { show("Deleted \(result.deleted) of \(result.requested) old saved Desktops. Some records could not be deleted: \(result.failures.joined(separator: " "))") }
    }

    @objc private func deleteAllSavedDesktops() {
        guard let desktopStore else { show("The saved Desktop store is unavailable."); return }
        let count = desktopStore.list().desktops.count
        let first = NSAlert(); first.messageText = "Delete all saved Desktops?"; first.informativeText = "All saved Desktop records will be removed. This cannot be undone through Deskriptions. Original applications, tabs, folders, and documents are not changed."; first.addButton(withTitle: "Continue"); first.addButton(withTitle: "Cancel")
        guard first.runModal() == .alertFirstButtonReturn else { return }
        let second = NSAlert(); second.messageText = "Permanently delete all \(count) saved Desktops?"; second.informativeText = "Only saved Desktop records are deleted. Settings, profiles, extensions, source content, and the Desktop naming counter remain unchanged."; second.addButton(withTitle: "Delete All Saved Desktops"); second.buttons.first?.hasDestructiveAction = true; second.addButton(withTitle: "Cancel")
        guard second.runModal() == .alertFirstButtonReturn else { return }
        do { let deleted = try desktopStore.deleteAll(); refreshDesktopManagement(); show("Deleted \(deleted) saved Desktop record(s). Original content was not changed.") }
        catch { refreshDesktopManagement(); show("Saved Desktops could not all be deleted safely: \(error.localizedDescription)") }
    }

    private func shortcutsView() -> NSView {
        let v = page(); heading("Keyboard Shortcuts", y: 445, in: v)
        let note = NSTextField(wrappingLabelWithString: "Choose Record, then press a modifier-key shortcut. Recording occurs only while the recorder is open."); note.frame = NSRect(x: 24, y: 400, width: 650, height: 38); v.addSubview(note)
        for (index, action) in ShortcutManager.Action.allCases.enumerated() {
            let y = CGFloat(345 - index * 58), name = NSTextField(labelWithString: action.title); name.frame = NSRect(x: 24, y: y, width: 220, height: 24); v.addSubview(name)
            let current = NSTextField(labelWithString: shortcuts.display(for: action).isEmpty ? "None" : shortcuts.display(for: action)); current.alignment = .center; current.font = .monospacedSystemFont(ofSize: 14, weight: .medium); current.frame = NSRect(x: 245, y: y, width: 100, height: 24); v.addSubview(current); shortcutLabels[action] = current
            let record = NSButton(title: "Record…", target: self, action: #selector(recordShortcut(_:))); record.tag = Int(action.rawValue); record.frame = NSRect(x: 360, y: y - 4, width: 90, height: 30); v.addSubview(record)
            let clear = NSButton(title: "Clear", target: self, action: #selector(clearShortcut(_:))); clear.tag = Int(action.rawValue); clear.frame = NSRect(x: 458, y: y - 4, width: 70, height: 30); v.addSubview(clear)
        }
        let defaults = NSButton(title: "Restore Defaults", target: self, action: #selector(restoreShortcuts)); defaults.frame = NSRect(x: 24, y: 120, width: 150, height: 32); v.addSubview(defaults)
        return v
    }
    @objc private func recordShortcut(_ sender: NSButton) {
        guard let action = ShortcutManager.Action(rawValue: UInt32(sender.tag)) else { return }
        let alert = NSAlert(); alert.messageText = "Record \(action.title)"; alert.informativeText = "Press the new shortcut now. Press Escape to cancel."; alert.addButton(withTitle: "Cancel")
        recordMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak alert] event in
            guard let self else { return event }; if event.keyCode == UInt16(kVK_Escape) { NSApp.abortModal(); return nil }
            guard let binding = shortcutFrom(event: event) else { NSSound.beep(); return nil }
            if let error = self.shortcuts.update(action, binding: binding) { alert?.informativeText = error; NSSound.beep() }
            else { self.shortcutLabels[action]?.stringValue = binding.display; NSApp.abortModal() }
            return nil
        }
        _ = alert.runModal(); if let recordMonitor { NSEvent.removeMonitor(recordMonitor) }; recordMonitor = nil
    }
    @objc private func clearShortcut(_ sender: NSButton) { guard let action = ShortcutManager.Action(rawValue: UInt32(sender.tag)) else { return }; _ = shortcuts.update(action, binding: nil); shortcutLabels[action]?.stringValue = "None" }
    @objc private func restoreShortcuts() { if let error = shortcuts.restoreDefaults() { show(error) }; for action in ShortcutManager.Action.allCases { shortcutLabels[action]?.stringValue = shortcuts.display(for: action) } }

    private func extensionsView() -> NSView {
        let v = page(); heading("Extensions", y: 445, in: v)
        let intro = NSTextField(wrappingLabelWithString: "Deskriptions is open source. Developers can build additional extensions. Official extensions are available from the project’s GitHub repository. Currently, browser extensions are installed using developer mode and are not available through extension stores."); intro.frame = NSRect(x: 24, y: 365, width: 650, height: 70); v.addSubview(intro)
        let github = NSButton(title: "Open Project on GitHub", target: self, action: #selector(openProject)); github.frame = NSRect(x: 24, y: 325, width: 180, height: 32); v.addSubview(github)
        let scroll = NSScrollView(frame: NSRect(x: 24, y: 20, width: 660, height: 295)); scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.borderType = .bezelBorder; scroll.autoresizingMask = [.width, .height]
        let document = FlippedView(frame: NSRect(x: 0, y: 0, width: 640, height: 295))
        let stack = NSStackView(); stack.translatesAutoresizingMaskIntoConstraints = false; stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        document.addSubview(stack); scroll.documentView = document
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 8),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -8),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)
        ])
        v.addSubview(scroll); extensionStack = stack; extensionDocumentView = document
        return v
    }
    private func refreshExtensions() {
        extensionRefreshGeneration += 1
        let generation = extensionRefreshGeneration
        extensionRefreshTask?.cancel()
        extensionRefreshTask = Task { [weak self] in
            guard let self else { return }
            let registrations = await bridge.extensionRegistrations(maxAge: 65)
            guard !Task.isCancelled, generation == extensionRefreshGeneration else { return }
            renderExtensions(registrations)
        }
    }
    private func renderExtensions(_ registrations: [ExtensionRegistration]) {
        guard let stack = extensionStack else { return }; stack.arrangedSubviews.forEach { stack.removeArrangedSubview($0); $0.removeFromSuperview() }
        let savedProfiles = desktopStore?.list().desktops.flatMap(\.profiles) ?? []
        let configuredIdentities = Set(ProfileConfigurationStore.all().keys)
        for browser in ChromiumBrowser.allCases {
            let observed = registrations.filter { $0.browserBundleID == browser.rawValue }
            let historicalIDs = Set(savedProfiles.filter { $0.applicationBundleID == browser.rawValue }.map(\.installationID))
                .union(configuredIdentities.compactMap { key in key.hasPrefix(browser.rawValue + "|") ? String(key.dropFirst(browser.rawValue.count + 1)) : nil })
            let observedIDs = Set(observed.compactMap(\.installationID))
            let unobserved = historicalIDs.subtracting(observedIDs).sorted()
            if observed.isEmpty && unobserved.isEmpty {
                let installed = NSWorkspace.shared.urlForApplication(withBundleIdentifier: browser.rawValue) != nil
                let detail = installed ? "● Disconnected · supported extension not currently registered" : "● Unavailable · browser is not installed"
                stack.addArrangedSubview(extensionRow(title: browser.displayName + " extension", detail: detail, green: false, bundleID: browser.rawValue, metadata: "External extension · protocol v\(protocolVersion) · window/tab inventory and restore"))
            }
            for registration in observed {
                guard let profile = registration.hello else { continue }
                let handshake = handshakeFormatter.string(from: registration.lastSeen)
                let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
                let compatibilityResult = AdapterCompatibility.evaluate(profile)
                let connected = registration.isConnected && compatibilityResult.isCompatible
                let state = registration.isConnected ? (compatibilityResult.isCompatible ? "Connected" : "Connected, incompatible") : "Disconnected"
                let age = registration.isConnected ? "last handshake \(handshake)" : "last seen \(handshake); handshake expired"
                let capabilities = profile.capabilities.sorted().joined(separator: ", ")
                let detail = "● \(state) · \(age)"
                let metadata = "External extension · adapter v\(profile.adapterVersion ?? "unknown") · app v\(appVersion) · \(compatibilityResult.explanation) · profile \(profile.installationID.prefix(8))\nCapabilities: \(capabilities.isEmpty ? "none reported" : capabilities)"
                let row = extensionRow(title: browser.displayName + " extension", detail: detail, green: connected, bundleID: browser.rawValue, metadata: metadata, profile: profile)
                let migrated = configuredPath(for: profile)
                if let field = row.viewWithTag(42) as? NSTextField { field.stringValue = migrated ?? "" }
                stack.addArrangedSubview(row)
            }
            for installationID in unobserved {
                let identity = "\(browser.rawValue)|\(installationID)"
                let metadata = "External extension · profile \(installationID.prefix(8)) · no handshake record is available"
                let row = extensionRow(title: browser.displayName + " extension", detail: "● Disconnected · known from saved configuration", green: false, bundleID: browser.rawValue, metadata: metadata, profileIdentity: identity)
                if let field = row.viewWithTag(42) as? NSTextField { field.stringValue = ProfileConfigurationStore.path(browser: browser.rawValue, installationID: installationID) ?? "" }
                stack.addArrangedSubview(row)
            }
        }
        for registration in registrations where registration.compatibility == .malformed {
            stack.addArrangedSubview(extensionRow(title: "Unrecognized extension registration", detail: "● Disconnected · handshake data is malformed", green: false, metadata: "External extension · last seen \(handshakeFormatter.string(from: registration.lastSeen)) · reload the supported browser extension"))
        }
        let previewRow = extensionRow(title: "Preview documents", detail: AXIsProcessTrusted() ? "● Available · Accessibility access granted" : "● Unavailable · Accessibility access is required for exact documents", green: AXIsProcessTrusted(), bundleID: PreviewAdapter.bundleIdentifier, metadata: AXIsProcessTrusted() ? "Native integration · exact AXDocument file identity, Preview-specific opening, and verification" : "Native integration · choose Grant Access, approve the running /Applications/Deskriptions.app in Privacy & Security → Accessibility, then relaunch Deskriptions if macOS does not apply the grant immediately", actionTitle: AXIsProcessTrusted() ? "Recheck" : "Grant Access…", action: #selector(grantPreviewAccessibility))
        let powerPointInstalled = NSWorkspace.shared.urlForApplication(withBundleIdentifier: PowerPointAdapter.bundleIdentifier) != nil
        let powerPointDetail = !powerPointInstalled ? "● Unavailable · Microsoft PowerPoint is not installed" : AXIsProcessTrusted() ? "● Available · Accessibility enabled; Automation may be requested for multiple files" : "● Unavailable · grant Accessibility for exact presentation identity"
        let powerPointRow = extensionRow(title: "Microsoft PowerPoint presentations", detail: powerPointDetail, green: powerPointInstalled && AXIsProcessTrusted(), bundleID: PowerPointAdapter.bundleIdentifier, metadata: "Native integration · exact AXDocument identity with PowerPoint Automation fallback for multiple presentations, explicit PowerPoint opening, and verification.", actionTitle: powerPointInstalled ? "Open Settings…" : nil, action: powerPointInstalled ? #selector(openAutomationSettings) : nil)
        let wordInstalled = NSWorkspace.shared.urlForApplication(withBundleIdentifier: WordAdapter.bundleIdentifier) != nil
        let wordRow = extensionRow(title: "Microsoft Word documents", detail: wordInstalled ? "● Available · Automation may be requested for exact files" : "● Unavailable · Microsoft Word is not installed", green: wordInstalled, bundleID: WordAdapter.bundleIdentifier, metadata: "Native integration · exact AXDocument identity with Word Automation fallback, explicit Word opening, and verification.", actionTitle: wordInstalled ? "Open Settings…" : nil, action: wordInstalled ? #selector(openAutomationSettings) : nil)
        let excelInstalled = NSWorkspace.shared.urlForApplication(withBundleIdentifier: ExcelAdapter.bundleIdentifier) != nil
        let excelRow = extensionRow(title: "Microsoft Excel workbooks", detail: excelInstalled ? "● Available · Automation may be requested for exact files" : "● Unavailable · Microsoft Excel is not installed", green: excelInstalled, bundleID: ExcelAdapter.bundleIdentifier, metadata: "Native integration · exact AXDocument identity with Excel Automation fallback, explicit Excel opening, and verification.", actionTitle: excelInstalled ? "Open Settings…" : nil, action: excelInstalled ? #selector(openAutomationSettings) : nil)
        for row in [
            extensionRow(title: "Finder folders", detail: "● Available · Automation permission requested when used", green: true, bundleID: "com.apple.finder", metadata: "Native integration · exact folder identity and reopening"),
            previewRow,
            powerPointRow,
            wordRow,
            excelRow,
            extensionRow(title: "Apple Notes", detail: "● Available · Automation permission requested when used", green: true, bundleID: NotesAdapter.bundleIdentifier, metadata: "Native integration · selected-note identity only"),
            extensionRow(title: "Application-only fallback", detail: "● Available · no additional permission required", green: true, metadata: "Native integration · launches applications; does not restore document or window contents")
        ] { stack.addArrangedSubview(row) }
        for row in stack.arrangedSubviews { row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        stack.layoutSubtreeIfNeeded()
        let height = max(extensionDocumentView?.enclosingScrollView?.contentSize.height ?? 0, stack.fittingSize.height + 16)
        extensionDocumentView?.frame.size.height = height
    }
    private var handshakeFormatter: DateFormatter { let f = DateFormatter(); f.dateStyle = .short; f.timeStyle = .medium; return f }
    private func configuredPath(for profile: ExtensionHello) -> String? {
        if let saved = ProfileConfigurationStore.path(browser: profile.browser, installationID: profile.installationID) { return saved }
        guard let desktopStore = try? DesktopStore.applicationSupport() else { return nil }
        let old = desktopStore.list().desktops.flatMap(\.profiles).first { $0.applicationBundleID == profile.browser && $0.installationID == profile.installationID }
        guard let root = old?.launchUserDataDirectory, let directory = old?.launchProfileDirectory else { return nil }
        let path = URL(fileURLWithPath: root).appendingPathComponent(directory).path
        ProfileConfigurationStore.set(path, browser: profile.browser, installationID: profile.installationID)
        return path
    }
    private func extensionRow(title: String, detail: String, green: Bool, bundleID: String? = nil, metadata: String, profile: ExtensionHello? = nil, profileIdentity: String? = nil, actionTitle: String? = nil, action: Selector? = nil) -> NSView {
        let hasProfile = profile != nil || profileIdentity != nil
        let row = NSView(frame: NSRect(x: 0, y: 0, width: 620, height: hasProfile ? 112 : 76)); row.translatesAutoresizingMaskIntoConstraints = false
        let icon = NSImageView(); icon.translatesAutoresizingMaskIntoConstraints = false
        if let bundleID {
            if let cached = integrationIconCache[bundleID] { icon.image = cached }
            else {
                let resolved = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSImage(systemSymbolName: "puzzlepiece.extension", accessibilityDescription: "Integration")!
                integrationIconCache[bundleID] = resolved; icon.image = resolved
            }
        } else { icon.image = NSImage(systemSymbolName: "puzzlepiece.extension", accessibilityDescription: "Integration") }
        let t = NSTextField(labelWithString: title); t.translatesAutoresizingMaskIntoConstraints = false; t.font = .systemFont(ofSize: 13, weight: .semibold)
        let d = NSTextField(labelWithString: detail); d.translatesAutoresizingMaskIntoConstraints = false; d.textColor = green ? .systemGreen : .systemRed
        let m = NSTextField(wrappingLabelWithString: metadata); m.translatesAutoresizingMaskIntoConstraints = false; m.textColor = .secondaryLabelColor; m.maximumNumberOfLines = 2
        row.addSubview(icon); row.addSubview(t); row.addSubview(d); row.addSubview(m)
        var titleTrailing = t.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -6)
        if let actionTitle, let action {
            let button = NSButton(title: actionTitle, target: self, action: action); button.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(button)
            titleTrailing = t.trailingAnchor.constraint(lessThanOrEqualTo: button.leadingAnchor, constant: -8)
            NSLayoutConstraint.activate([button.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -6), button.topAnchor.constraint(equalTo: row.topAnchor), button.widthAnchor.constraint(greaterThanOrEqualToConstant: 92)])
        }
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: hasProfile ? 112 : 76),
            icon.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 6), icon.topAnchor.constraint(equalTo: row.topAnchor, constant: 7), icon.widthAnchor.constraint(equalToConstant: 28), icon.heightAnchor.constraint(equalToConstant: 28),
            t.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10), t.topAnchor.constraint(equalTo: row.topAnchor, constant: 4), titleTrailing,
            d.leadingAnchor.constraint(equalTo: t.leadingAnchor), d.topAnchor.constraint(equalTo: t.bottomAnchor, constant: 1), d.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -6),
            m.leadingAnchor.constraint(equalTo: t.leadingAnchor), m.topAnchor.constraint(equalTo: d.bottomAnchor, constant: 1), m.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -6)
        ])
        if hasProfile {
            let field = NSTextField(); field.translatesAutoresizingMaskIntoConstraints = false; field.tag = 42; field.placeholderString = "Complete browser Profile Path"; field.target = self; field.action = #selector(profilePathChanged(_:)); field.identifier = NSUserInterfaceItemIdentifier(profile?.identityKey ?? profileIdentity!)
            row.addSubview(field)
            NSLayoutConstraint.activate([field.leadingAnchor.constraint(equalTo: t.leadingAnchor), field.topAnchor.constraint(equalTo: m.bottomAnchor, constant: 4), field.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -6), field.heightAnchor.constraint(equalToConstant: 24)])
        }
        return row
    }
    @objc private func grantPreviewAccessibility() {
        if !AXIsProcessTrusted() {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self else { return }
                if !AXIsProcessTrusted(), let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                    NSWorkspace.shared.open(url)
                }
                self.refreshExtensions(); self.refreshDiagnostics()
            }
            Task { @MainActor [weak self] in
                for _ in 0..<15 {
                    try? await Task.sleep(for: .seconds(2))
                    guard let self else { return }
                    self.refreshExtensions(); self.refreshDiagnostics()
                    if AXIsProcessTrusted() { return }
                }
            }
        } else {
            refreshExtensions(); refreshDiagnostics()
        }
    }
    @objc private func openAutomationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") { NSWorkspace.shared.open(url) }
    }
    @objc private func profilePathChanged(_ sender: NSTextField) { guard let identity = sender.identifier?.rawValue, let split = identity.firstIndex(of: "|") else { return }; let browser = String(identity[..<split]), id = String(identity[identity.index(after: split)...]); let path = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines); if !path.isEmpty && !path.hasPrefix("/") { show("Profile Path must be a complete absolute path."); return }; ProfileConfigurationStore.set(path.isEmpty ? nil : path, browser: browser, installationID: id) }
    @objc private func openProject() { NSWorkspace.shared.open(URL(string: "https://github.com/B1s9l/deskription")!) }

    private func diagnosticsView() -> NSView {
        let v = page(); heading("Diagnostics", y: 445, in: v); let label = NSTextField(wrappingLabelWithString: "Checking…"); label.font = .monospacedSystemFont(ofSize: 11, weight: .regular); label.frame = NSRect(x: 24, y: 280, width: 650, height: 150); v.addSubview(label); diagnosticsLabel = label
        let buttons: [(String, Selector)] = [("Setup & permission status…", #selector(openLegacySetup)), ("Print native inventory", #selector(nativeInventory)), ("Export Diagnostics…", #selector(exportDiagnostics)), ("Recent Status…", #selector(recentStatus))]
        for (index,item) in buttons.enumerated() { let b = NSButton(title:item.0,target:self,action:item.1); b.frame = NSRect(x:24+CGFloat(index%2)*220,y:230-CGFloat(index/2)*42,width:205,height:32); v.addSubview(b) }
        return v
    }
    private func refreshDiagnostics() { Task { let profiles = await bridge.connectedProfiles(), issues = await bridge.connectionIssueCounts(); await MainActor.run { self.diagnosticsLabel?.stringValue = "Browser extension connections: \(profiles.count) live (65-second freshness)\nIncompatible observations: \(issues.incompatible)\nAccessibility: \(AXIsProcessTrusted() ? "working for exact document identity" : "optional; used for Accessibility document identity")\nAutomation: requested only by Finder, Notes, PowerPoint, Word, and Excel when needed\nScreen Recording: not used\nMission Control automation: not used" } } }
    @objc private func openLegacySetup() { (NSApp.delegate as? AppDelegate)?.showSetupFromSettings() }
    @objc private func nativeInventory() { actions.nativeInventory() }; @objc private func exportDiagnostics() { actions.exportDiagnostics() }; @objc private func recentStatus() { actions.recentStatus() }

    private func creditsView() -> NSView {
        let v = page(); heading("Deskriptions", y: 445, in: v); let version = Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "development", build = Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion") as? String ?? "development"
        let text = NSTextField(wrappingLabelWithString: "Version \(version) (build \(build))\n\nDeskriptions is open-source software licensed under GNU GPL version 3 only (GPL-3.0-only). Copyright © 2026 B1s9l.\n\nCreator\nB1s9l\n\nContributor credits are structured to allow additions without changing application behavior.\n\nNo additional menu-bar font is bundled; the script D uses a macOS system font. The complete license and third-party notices are included with the packaged documentation."); text.frame = NSRect(x:24,y:160,width:650,height:260); v.addSubview(text)
        let creator = NSButton(title:"B1s9l on GitHub",target:self,action:#selector(openCreator)); creator.frame=NSRect(x:24,y:110,width:150,height:32); v.addSubview(creator); let project=NSButton(title:"Project Repository",target:self,action:#selector(openProject));project.frame=NSRect(x:184,y:110,width:160,height:32);v.addSubview(project); return v
    }
    @objc private func openCreator() { NSWorkspace.shared.open(URL(string:"https://github.com/B1s9l")!) }
    private func show(_ text: String) { let a=NSAlert();a.messageText="Deskriptions Settings";a.informativeText=text;a.runModal() }
}

private final class FlippedView: NSView { override var isFlipped: Bool { true } }
