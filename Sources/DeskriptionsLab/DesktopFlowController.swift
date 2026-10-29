import AppKit
import CoreGraphics
import DeskriptionsCore
import UniformTypeIdentifiers

@MainActor
final class DesktopFlowController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private let bridge = FileAdapterBridge()
    private let finderAdapter = FinderAdapter()
    private let previewAdapter = PreviewAdapter()
    private let notesAdapter = NotesAdapter()
    private let genericAdapter = GenericApplicationAdapter()
    private let status = TransientStatusController()
    private let store: DesktopStore
    private let attemptStore: LoadAttemptStore
    private let afterSavePreferences = AfterSavePreferenceStore()
    private let retentionPreferences = DesktopRetentionPreferences()
    private let nameCounter = DesktopNameCounter()
    private var profiles: [ExtensionHello] = []
    private var associations: [String: [WindowAssociation]] = [:]
    private var selection = DesktopSelection()
    private var finderFolders: [FinderFolderObservation] = []
    private var selectedFinderWindowIDs = Set<Int>()
    private var previewDocuments: [PreviewDocumentObservation] = []
    private var selectedPreviewPaths = Set<String>()
    private var noteObservations: [NoteObservation] = []
    private var selectedNoteIDs = Set<String>()
    private var genericApplications: [GenericApplicationObservation] = []
    private var selectedGenericBundleIDs = Set<String>()
    private var rows: [Row] = []
    private var table: NSTableView?
    private var nameField: NSTextField?
    private var initialAll = UserDefaults.standard.bool(forKey: "initialSelectionAll")
    private var saveInfoPopover: NSPopover?
    private var desktopsBrowser: DesktopsBrowserController?
    private var cancellationRequested = false
    private var activeOperationID: UUID?
    private var activeProfiles: [(installationID: String, browserBundleID: String)] = []
    private var faviconCache: [String: NSImage] = [:]
    private var faviconLoads = Set<String>()
    private var applicationIconCache: [String: NSImage] = [:]

    override init() {
        store = (try? .applicationSupport()) ?? DesktopStore(directory: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Deskriptions-Desktops"))
        attemptStore = (try? .applicationSupport()) ?? LoadAttemptStore(directory: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Deskriptions-Operations"))
        super.init()
    }

    func openSaveDesktop() {
        NSApp.activate(ignoringOtherApps: true)
        Task {
            var connected = await bridge.connectedProfiles()
            for profile in connected { _ = try? await bridge.send(.init(type: "freshInventory"), to: profile.installationID, browserBundleID: profile.browser, timeout: 5) }
            connected = await bridge.connectedProfiles()
            let native = allNativeWindows()
            let finder = Result { try finderAdapter.inventory() }, preview = Result { try previewAdapter.inventory() }, notes = Result { try notesAdapter.inventory() }
            var dedicated = Set(connected.map(\.browser)); if (try? preview.get().isEmpty) == false { dedicated.insert(PreviewAdapter.bundleIdentifier) }; if (try? notes.get().isEmpty) == false { dedicated.insert(NotesAdapter.bundleIdentifier) }
            let generic = genericAdapter.inventory(nativeWindows: native, ownBundleID: Bundle.main.bundleIdentifier, integratedBrowserBundleIDs: dedicated)
            presentSave(profiles: connected, finderFolders: (try? finder.get()) ?? [], previewDocuments: (try? preview.get()) ?? [], notes: (try? notes.get()) ?? [], genericApplications: generic, integrationErrors: [finder.failureDescription, preview.failureDescription, notes.failureDescription].compactMap { $0 })
        }
    }

    private func presentSave(profiles: [ExtensionHello], finderFolders: [FinderFolderObservation], previewDocuments: [PreviewDocumentObservation], notes: [NoteObservation], genericApplications: [GenericApplicationObservation], integrationErrors: [String]) {
        initialAll = UserDefaults.standard.bool(forKey: "initialSelectionAll")
        self.profiles = profiles; self.associations = buildAssociations(profiles)
        self.finderFolders = finderFolders
        self.previewDocuments = previewDocuments; self.noteObservations = notes
        self.genericApplications = genericApplications
        selection = DesktopSelection()
        selectedFinderWindowIDs.removeAll()
        selectedPreviewPaths.removeAll(); selectedNoteIDs.removeAll()
        selectedGenericBundleIDs.removeAll()
        if initialAll { for profile in profiles { profile.windows.forEach { selection.set(window: $0, profileID: profile.identityKey, selected: true) } } }
        else {
            for profile in profiles { for window in profile.windows {
                let match = associations[profile.identityKey]?.first { $0.browserWindowID == window.extensionWindowID }
                if let nativeID = match?.nativeWindowID, nativeWindow(nativeID)?.onScreen == true { selection.set(window: window, profileID: profile.identityKey, selected: true) }
            }}
        }
        if initialAll { selectedFinderWindowIDs = Set(finderFolders.map(\.windowID)) }
        else { selectedFinderWindowIDs = Set(finderFolders.filter(\.onScreen).map(\.windowID)) }
        selectedPreviewPaths = Set(previewDocuments.filter { initialAll || $0.onScreen }.map(\.path))
        selectedNoteIDs = Set(notes.filter { initialAll || $0.onScreen }.map(\.identifier))
        selectedGenericBundleIDs = ApplicationFallback.initialSelection(visibility: Dictionary(uniqueKeysWithValues: genericApplications.map { ($0.bundleIdentifier, $0.hasOnScreenWindow) }), selectAll: initialAll)
        rebuildRows()
        let alert = NSAlert(); alert.messageText = "Save Desktop"; alert.informativeText = "Choose what to include."
        let finderStatus = integrationErrors.isEmpty ? " Finder folders and supported Preview/Notes items can be reopened by their verified identities." : " Some built-in integrations are unavailable: \(integrationErrors.joined(separator: " "))"
        let explanation = "Select supported windows or contents. Windows not confirmed on screen remain available for manual selection. On screen does not mean unobscured. Application-only items reopen the application but remain open after saving; window contents are not restored." + finderStatus
        alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Cancel")
        alert.buttons[0].keyEquivalent = "\r"; alert.buttons[1].keyEquivalent = "\u{1b}"
        let containerHeight: CGFloat = 455
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 680, height: containerHeight))
        let name = NSTextField(frame: NSRect(x: 0, y: containerHeight - 38, width: 635, height: 28)); name.stringValue = defaultName(); name.placeholderString = "Desktop name"; container.addSubview(name); nameField = name
        let info = NSButton(image: NSImage(systemSymbolName:"info.circle",accessibilityDescription:"Save Desktop information")!, target:self, action:#selector(showSaveInfo(_:))); info.bezelStyle = .accessoryBarAction; info.frame=NSRect(x:642,y:containerHeight-38,width:30,height:28); info.toolTip="Restoration information and limitations"; info.identifier=NSUserInterfaceItemIdentifier(explanation); container.addSubview(info)
        let table = NSTableView(frame: .zero); table.headerView = nil; table.delegate = self; table.dataSource = self; table.rowHeight = 25
        // Keep the native checkbox as the primary control, but make the full row
        // actionable too.  This also gives keyboard/table users a reliable path
        // when an accessibility client cannot invoke a checkbox embedded in a
        // view-based NSTableView cell.
        table.target = self; table.action = #selector(toggleSelectedTableRow(_:))
        table.addTableColumn(NSTableColumn(identifier: .init("item")))
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 62, width: 680, height: 345)); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder; container.addSubview(scroll); self.table = table
        let all = NSButton(title: "Select all", target: self, action: #selector(selectAll)); all.frame = NSRect(x: 0, y: 25, width: 110, height: 28); container.addSubview(all)
        let none = NSButton(title: "Unselect all", target: self, action: #selector(unselectAll)); none.frame = NSRect(x: 115, y: 25, width: 110, height: 28); container.addSubview(none)
        let missing = profiles.filter { ProfileConfigurationStore.path(browser:$0.browser,installationID:$0.installationID) == nil }
        let withoutFavicons = profiles.filter { !$0.capabilities.contains("inventory.favicons.data-v1") }
        let packagedAdapterVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let mismatchedAdapters = profiles.filter { $0.adapterVersion != packagedAdapterVersion }
        var notices: [String] = []
        if !missing.isEmpty { notices.append("Cold launch path missing for \(missing.count) browser profile(s). Configure in Settings → Extensions.") }
        if !withoutFavicons.isEmpty || !mismatchedAdapters.isEmpty { notices.append("Reload the matching browser extension to enable reliable tab favicons.") }
        let note = NSTextField(labelWithString: notices.joined(separator: " ")); note.frame = NSRect(x: 235, y: 25, width: 440, height: 34); note.maximumNumberOfLines = 2; note.textColor = .secondaryLabelColor; container.addSubview(note)
        alert.accessoryView = container; table.reloadData()
        (alert.window.fieldEditor(true, for: name) as? NSTextView)?.allowsUndo = true
        if alert.runModal() == .alertFirstButtonReturn { commitSave() }
        self.table = nil; nameField = nil
    }

    @objc private func selectAll() { for profile in profiles { profile.windows.forEach { selection.set(window: $0, profileID: profile.identityKey, selected: true) } }; selectedFinderWindowIDs = Set(finderFolders.map(\.windowID)); selectedPreviewPaths = Set(previewDocuments.map(\.path)); selectedNoteIDs = Set(noteObservations.map(\.identifier)); selectedGenericBundleIDs = Set(genericApplications.map(\.bundleIdentifier)); rebuildRows(); table?.reloadData() }
    @objc private func unselectAll() { selection.content.removeAll(); selectedFinderWindowIDs.removeAll(); selectedPreviewPaths.removeAll(); selectedNoteIDs.removeAll(); selectedGenericBundleIDs.removeAll(); rebuildRows(); table?.reloadData() }
    @objc private func showSaveInfo(_ sender:NSButton){let pop=NSPopover();let controller=NSViewController();let text=NSTextField(wrappingLabelWithString:sender.identifier?.rawValue ?? "");text.frame=NSRect(x:16,y:16,width:420,height:150);controller.view=NSView(frame:NSRect(x:0,y:0,width:452,height:182));controller.view.addSubview(text);pop.contentViewController=controller;pop.behavior = .transient;pop.show(relativeTo:sender.bounds,of:sender,preferredEdge:.maxY);saveInfoPopover=pop}
    @objc private func toggleRow(_ sender: NSButton) {
        let index = sender.tag
        guard rows.indices.contains(index) else { return }
        // A mixed state is meaningful for parent rows, but AppKit may also
        // transiently cycle an ordinary checkbox through mixed. Treat every
        // non-off click as selection so leaf rows remain directly usable.
        setRow(index, selected: sender.state != .off)
    }

    @objc private func toggleSelectedTableRow(_ sender: NSTableView) {
        let index = sender.clickedRow >= 0 ? sender.clickedRow : sender.selectedRow
        guard rows.indices.contains(index) else { return }
        let selected: Bool
        switch rows[index].state {
        case .on: selected = false
        case .off, .mixed: selected = true
        }
        setRow(index, selected: selected)
    }

    private func setRow(_ index: Int, selected: Bool) {
        switch rows[index].kind {
        case .profile(let p): for w in profiles[p].windows { selection.set(window: w, profileID: profiles[p].identityKey, selected: selected) }
        case .window(let p, let w): selection.set(window: profiles[p].windows[w], profileID: profiles[p].identityKey, selected: selected)
        case .tab(let p, _, let id): selection.set(tabID: id, profileID: profiles[p].identityKey, selected: selected)
        case .finderFolder(let index): if selected { selectedFinderWindowIDs.insert(finderFolders[index].windowID) } else { selectedFinderWindowIDs.remove(finderFolders[index].windowID) }
        case .previewDocument(let index): if selected { selectedPreviewPaths.insert(previewDocuments[index].path) } else { selectedPreviewPaths.remove(previewDocuments[index].path) }
        case .note(let index): if selected { selectedNoteIDs.insert(noteObservations[index].identifier) } else { selectedNoteIDs.remove(noteObservations[index].identifier) }
        case .genericApplication(let index): if selected { selectedGenericBundleIDs.insert(genericApplications[index].bundleIdentifier) } else { selectedGenericBundleIDs.remove(genericApplications[index].bundleIdentifier) }
        case .unsupported: break
        }
        rebuildRows(); table?.reloadData()
    }

    private func commitSave() {
        guard !selection.content.isEmpty || !selectedFinderWindowIDs.isEmpty || !selectedPreviewPaths.isEmpty || !selectedNoteIDs.isEmpty || !selectedGenericBundleIDs.isEmpty else { show("Nothing selected", "Select at least one supported item."); return }
        let name = nameField?.stringValue.isEmpty == false ? nameField!.stringValue : defaultName()
        let directories = Dictionary(uniqueKeysWithValues: profiles.compactMap { profile in ProfileConfigurationStore.path(browser:profile.browser,installationID:profile.installationID).map { (profile.identityKey,$0) } })
        let selected = selection.content
        Task {
            let selectedProfileIDs = Set(selected.map(\.profileID))
            for profile in profiles where selectedProfileIDs.contains(profile.identityKey) {
                do { _ = try await bridge.send(.init(type: "freshInventory"), to: profile.installationID, browserBundleID: profile.browser, timeout: 35) }
                catch { await MainActor.run { show("Desktop wasn’t saved", "Fresh \(ChromiumBrowser.displayName(for: profile.browser)) state was required but unavailable: \(error.localizedDescription)") }; return }
            }
            let fresh = await bridge.connectedProfiles()
            let available = Set(fresh.flatMap { profile in profile.windows.flatMap(\.tabs).map { ContentIdentity(profileID: profile.identityKey, tabID: $0.id) } })
            guard selected.isSubset(of: available) else {
                await MainActor.run { show("Inventory changed", "A selected tab moved or disappeared. Review the inventory and save again; nothing was closed.") }; return
            }
            let freshFinder: [FinderFolderObservation]
            if selectedFinderWindowIDs.isEmpty { freshFinder = [] }
            else {
                do { freshFinder = try finderAdapter.inventory() }
                catch { show("Desktop wasn’t saved", "Fresh Finder state was required but unavailable: \(error.localizedDescription)"); return }
            }
            let selectedFinder = finderFolders.filter { selectedFinderWindowIDs.contains($0.windowID) }
            guard selectedFinder.allSatisfy({ selected in freshFinder.contains(where: { $0.windowID == selected.windowID && standardized($0.path) == standardized(selected.path) }) }) else {
                show("Inventory changed", "A selected Finder window changed or disappeared. Review the inventory and save again; nothing was closed."); return
            }
            let freshPreview: [PreviewDocumentObservation]
            do { freshPreview = selectedPreviewPaths.isEmpty ? [] : try previewAdapter.inventory() }
            catch { show("Desktop wasn’t saved", error.localizedDescription); return }
            guard selectedPreviewPaths.isSubset(of: Set(freshPreview.map(\.path))) else { show("Inventory changed", "A selected Preview document changed or disappeared. Review the inventory and save again; nothing was closed."); return }
            let freshNotes: [NoteObservation]
            do { freshNotes = selectedNoteIDs.isEmpty ? [] : try notesAdapter.inventory() }
            catch { show("Desktop wasn’t saved", error.localizedDescription); return }
            guard selectedNoteIDs.isSubset(of: Set(freshNotes.map(\.identifier))) else { show("Inventory changed", "A selected note changed or disappeared. Review the inventory and save again; nothing was closed."); return }
            var dedicated = Set(fresh.map(\.browser))
            if !freshPreview.isEmpty { dedicated.insert(PreviewAdapter.bundleIdentifier) }
            if !freshNotes.isEmpty { dedicated.insert(NotesAdapter.bundleIdentifier) }
            let freshGeneric = genericAdapter.inventory(nativeWindows: allNativeWindows(), ownBundleID: Bundle.main.bundleIdentifier, integratedBrowserBundleIDs: dedicated)
            guard selectedGenericBundleIDs.isSubset(of: Set(freshGeneric.map(\.bundleIdentifier))) else {
                show("Inventory changed", "A selected application closed or became unavailable. Review the inventory and save again; nothing was closed."); return
            }
            persistAndFinish(name: name, directories: directories, freshProfiles: fresh, freshFinder: freshFinder, freshPreview: freshPreview, freshNotes: freshNotes, freshGeneric: freshGeneric)
        }
    }

    private func persistAndFinish(name: String, directories: [String: String], freshProfiles: [ExtensionHello], freshFinder: [FinderFolderObservation], freshPreview: [PreviewDocumentObservation], freshNotes: [NoteObservation], freshGeneric: [GenericApplicationObservation]) {
        profiles = freshProfiles
        associations = buildAssociations(freshProfiles)
        let savedProfiles = freshProfiles.compactMap { profile -> BrowserProfileState? in
            let matches = associations[profile.identityKey] ?? []
            let windows = profile.windows.compactMap { window -> SavedWindow? in
                let tabs = window.tabs.filter { selection.contains(tabID: $0.id, profileID: profile.identityKey) }.sorted { $0.index < $1.index }.enumerated().map { offset, tab in
                    SavedTab(sourceTabID: tab.id, url: tab.url, title: tab.title, pinned: tab.pinned, active: tab.active, order: offset, faviconDataURL: tab.faviconDataURL)
                }
                guard !tabs.isEmpty else { return nil }
                let native = matches.first { $0.browserWindowID == window.extensionWindowID }
                return SavedWindow(sourceExtensionWindowID: window.extensionWindowID, verifiedNativeWindowID: native?.status == .matched ? native?.nativeWindowID : nil, frame: window.bounds, state: window.state, tabs: tabs)
            }
            guard !windows.isEmpty else { return nil }
            let candidate = directories[profile.identityKey]
            let locator = candidate?.isEmpty == false ? candidate : nil
            let full = locator.map { URL(fileURLWithPath: $0) }
            return BrowserProfileState(applicationBundleID: profile.browser, installationID: profile.installationID, adapterStateVersion: profile.savedStateVersion, launchUserDataDirectory: locator?.hasPrefix("/") == true ? full?.deletingLastPathComponent().path : nil, launchProfileDirectory: locator?.hasPrefix("/") == true ? full?.lastPathComponent : locator, windows: windows)
        }
        let savedFinder = freshFinder.filter { selectedFinderWindowIDs.contains($0.windowID) }.map { SavedFinderFolder(sourceWindowID:$0.windowID,path:$0.path,frame:$0.frame) }
        let savedPreview = freshPreview.filter { selectedPreviewPaths.contains($0.path) }.map { SavedPreviewDocument(path: $0.path, displayName: $0.displayName) }
        let savedNotes = freshNotes.filter { selectedNoteIDs.contains($0.identifier) }.map { SavedNote(noteIdentifier: $0.identifier, displayName: $0.displayName) }
        let savedApplications = ApplicationFallback.deduplicated(freshGeneric.filter { selectedGenericBundleIDs.contains($0.bundleIdentifier) }.map { SavedApplication(bundleIdentifier: $0.bundleIdentifier, displayName: $0.displayName, savedBundlePath: $0.bundlePath) })
        let desktop = SavedDesktop(name: name, profiles: savedProfiles, finderFolders: savedFinder, previewDocuments: savedPreview, notes: savedNotes, applications: savedApplications, limitations: ["Restoration opens windows in the current working environment. Window placement is not independently verified.", "Finder folders and Notes remain open after saving.", "Preview documents close only when their exact Accessibility document identity is still verified; unsaved-change prompts are preserved.", "Application-only entries reopen the application; their window contents are not restored and their windows remain open after saving.", "Page-internal state and protected content are not saved."])
        let behavior = afterSavePreferences.behavior(hasExistingDesktops: !store.list().desktops.isEmpty)
        do { try store.save(desktop); advanceDesktopCounter() } catch { show("Desktop wasn’t saved", error.localizedDescription); return }
        if retentionPreferences.isEnabled {
            let retention = store.applyRetention(limit: retentionPreferences.limit, protecting: desktop.id)
            if !retention.failures.isEmpty {
                status.record(title: "Desktop saved; automatic deletion incomplete", detail: "Deleted \(retention.deleted) of \(retention.requested) old saved Desktops. \(retention.failures.joined(separator: " "))")
            } else if retention.deleted > 0 {
                status.record(title: "Old saved Desktops deleted", detail: "Kept the newest \(retentionPreferences.limit) saved Desktops and deleted \(retention.deleted) older record(s).")
            }
        }
        guard let postSaveDecision = AfterSavePolicy.decision(persistenceSucceeded: true, behavior: behavior) else { return }
        switch postSaveDecision {
        case .keepOpen:
            reportKeptOpen(desktop)
        case .closeSupportedContent:
            Task { await closeSavedContent(desktop, sourceProfiles: freshProfiles) }
        case .prompt:
            presentAfterSaveChoice(for: desktop, sourceProfiles: freshProfiles)
        }
    }

    private func presentAfterSaveChoice(for desktop: SavedDesktop, sourceProfiles: [ExtensionHello]) {
        let alert = NSAlert()
        alert.messageText = "Desktop saved successfully"
        alert.informativeText = "What would you like to do with the selected content?"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Keep Open")
        alert.addButton(withTitle: "Close Supported Content")
        // Escape is a dismissal and must take the safe path. Return still invokes
        // the first NSAlert button through AppKit's normal default-button behavior.
        alert.buttons.first?.keyEquivalent = "\u{1b}"
        alert.buttons.first?.setAccessibilityLabel("Keep selected content open")
        alert.buttons.last?.setAccessibilityLabel("Close selected content supported by a safe-close integration")
        let choice: AfterSavePromptChoice = alert.runModal() == .alertSecondButtonReturn ? .closeSupportedContent : .keepOpen
        if AfterSavePolicy.decision(after: choice) == .closeSupportedContent {
            Task { await closeSavedContent(desktop, sourceProfiles: sourceProfiles) }
        } else {
            reportKeptOpen(desktop)
        }
    }

    private func reportKeptOpen(_ desktop: SavedDesktop) {
        let summary = DesktopPresentation.summary(for: desktop).text
        status.show(title: "Desktop saved", detail: "\(summary). Selected content was kept open.", duration: 5)
    }

    private func closeSavedContent(_ desktop: SavedDesktop, sourceProfiles: [ExtensionHello]) async {
        var messages: [String] = desktop.finderFolders.isEmpty ? [] : ["Finder folders saved; Finder windows were left open because their complete tab contents cannot be verified."]
        if !desktop.notes.isEmpty { messages.append("Selected notes were saved; Notes windows were left open because safe selective closure is not supported.") }
        if !desktop.applications.isEmpty { messages.append("Application-only entries saved; their applications were left open because Deskriptions cannot distinguish unrelated or unsaved windows safely.") }
        var supportedOperations = 0
        var failedOperations = 0
        for savedProfile in desktop.profiles {
            supportedOperations += 1
            guard let source = sourceProfiles.first(where: { $0.installationID == savedProfile.installationID && $0.browser == savedProfile.applicationBundleID }) else { failedOperations += 1; messages.append("Profile disconnected after save; its content was left open."); continue }
            let targets: [JSONValue] = savedProfile.windows.compactMap { saved in
                guard let windowID = saved.sourceExtensionWindowID, let live = source.windows.first(where: { $0.extensionWindowID == windowID }) else { return nil }
                let selected = saved.tabs.compactMap(\.sourceTabID)
                return .object(["windowID":.number(Double(windowID)),"expectedSessionID":.string(source.sessionID),"expectedTabIDs":.array(live.tabs.map { .number(Double($0.id)) }),"tabIDs":.array(selected.map { .number(Double($0)) }),"closeWholeWindow":.bool(selected.count == live.tabs.count),"nativeAssociationVerified":.bool(saved.verifiedNativeWindowID != nil)])
            }
            do {
                let response = try await bridge.send(.init(type:"closeSelected", operationID:UUID().uuidString, payload:.object(["targets":.array(targets)])), to:savedProfile.installationID, browserBundleID:savedProfile.applicationBundleID)
                messages.append("Close result: \(response.status ?? "unknown").")
                if response.status != "complete" { failedOperations += 1 }
            } catch { failedOperations += 1; messages.append("Closing failed: \(error.localizedDescription)") }
        }
        for document in desktop.previewDocuments {
            supportedOperations += 1
            do {
                if try await previewAdapter.close(document) { messages.append("Preview closed \(document.displayName).") }
                else { failedOperations += 1; messages.append("Preview kept \(document.displayName) open because closure was unavailable, cancelled, or awaiting an unsaved-change decision.") }
            } catch { failedOperations += 1; messages.append("Preview kept \(document.displayName) open: \(error.localizedDescription)") }
        }
        if supportedOperations == 0 { messages.append("No selected content supports safe closing; everything remained open.") }
        let title = failedOperations > 0 ? "Desktop saved; some content stayed open" : "Desktop saved"
        if supportedOperations > 0 && failedOperations == 0 { messages.insert("Supported browser content was closed.", at: 0) }
        await MainActor.run { status.show(title: title, detail: messages.joined(separator:" "), duration: 6) }
    }

    func openDesktops() {
        NSApp.activate(ignoringOtherApps: true)
        let listing = store.list()
        guard !listing.desktops.isEmpty else { status.show(title: "No saved Desktops", detail: listing.errors.first?.localizedDescription ?? "Save a Desktop first."); return }
        desktopsBrowser?.close()
        desktopsBrowser = DesktopsBrowserController(desktops: listing.desktops, icon: { [weak self] in self?.applicationIcon(for: $0) ?? NSImage() }, onLoad: { [weak self] desktop in
            Task { await self?.prepareLoad(desktop) }
        }, onDelete: { [weak self] desktop in self?.confirmDelete(desktop) })
        desktopsBrowser?.show()
        if !listing.errors.isEmpty { status.show(title: "Some Desktops were skipped", detail: "Corrupt or incompatible saved records were left unchanged.") }
    }

    func showRecentStatus() { status.showHistory() }

    func exportDiagnostics() {
        NSApp.activate(ignoringOtherApps: true)
        Task {
            let connected = await bridge.connectedProfiles()
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
            let report = DiagnosticExporter.makeReport(appVersion: version, desktopStore: store, attemptStore: attemptStore, connectedProfiles: connected)
            let panel = NSSavePanel(); panel.nameFieldStringValue = "Deskriptions Diagnostics.json"
            panel.allowedContentTypes = [.json]
            panel.message = report.privacyNotice
            guard panel.runModal() == .OK, let url = panel.url else { return }
            do {
                try DiagnosticExporter.encode(report).write(to: url, options: .atomic)
                show("Diagnostics exported", "The report contains counts and version information only. It excludes URLs, page titles, Desktop names, profile identities, credentials, and saved Desktop contents.")
            } catch { show("Diagnostics export failed", error.localizedDescription) }
        }
    }

    private func confirmDelete(_ desktop: SavedDesktop) {
        let one=NSAlert(); one.messageText="Delete saved Desktop ‘\(desktop.name)’?"; one.informativeText="This deletes only the saved Desktop record, never browser content."; one.addButton(withTitle:"Continue"); one.addButton(withTitle:"Cancel")
        guard one.runModal() == .alertFirstButtonReturn else{return}
        let two=NSAlert(); two.messageText="Confirm deletion"; two.informativeText="Delete ‘\(desktop.name)’ permanently?"; two.addButton(withTitle:"Delete saved Desktop"); two.addButton(withTitle:"Cancel")
        guard two.runModal() == .alertFirstButtonReturn else{return}
        do {
            try store.delete(desktop.id)
            desktopsBrowser?.close(); desktopsBrowser = nil
            status.show(title: "Saved Desktop deleted", detail: "Original application and browser content was not changed.")
            openDesktops()
        } catch { status.show(title: "Deletion failed", detail: error.localizedDescription, duration: 8) }
    }

    private func prepareLoad(_ original: SavedDesktop) async {
        var desktop = original
        let live = await bridge.connectedProfiles()
        let liveIDs = Set(live.map { $0.identityKey })
        let missing = desktop.profiles.filter { !$0.browserIdentityVerified || (!liveIDs.contains("\($0.applicationBundleID)|\($0.installationID)") && ($0.launchUserDataDirectory == nil || $0.launchProfileDirectory == nil)) }
        if !missing.isEmpty {
            guard !live.isEmpty else {
                let alert = NSAlert(); alert.messageText = "Browser profile isn’t connected"
                alert.informativeText = "This saved Desktop has no verified browser/profile mapping. Open the intended Chromium browser profile, enable the matching Deskriptions extension, then choose Retry. Deskriptions will never substitute another browser or profile silently."
                alert.addButton(withTitle: "Retry"); alert.addButton(withTitle: "Open Setup"); alert.addButton(withTitle: "Cancel")
                let answer = alert.runModal()
                if answer == .alertFirstButtonReturn { await prepareLoad(original) }
                else if answer == .alertSecondButtonReturn { NSApp.sendAction(#selector(AppDelegate.showSetupFromFlow), to: nil, from: nil) }
                return
            }
            var replacements: [String: ExtensionHello] = [:]
            for saved in missing {
                let alert = NSAlert(); alert.messageText = "Associate saved browser profile"
                alert.informativeText = "The older saved identity \(saved.installationID.prefix(8)) is unavailable or may name the wrong Chromium browser. Choose the verified live browser/profile that owns this Desktop, or cancel."
                let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 430, height: 28))
                for profile in live { popup.addItem(withTitle: "\(ChromiumBrowser.displayName(for: profile.browser)) profile \(profile.installationID.prefix(8)) — extension \(profile.adapterVersion ?? "unknown")") }
                alert.accessoryView = popup; alert.addButton(withTitle: "Associate profile"); alert.addButton(withTitle: "Cancel")
                guard alert.runModal() == .alertFirstButtonReturn else { return }
                replacements["\(saved.applicationBundleID)|\(saved.installationID)"] = live[popup.indexOfSelectedItem]
            }
            let profiles = desktop.profiles.map { saved -> BrowserProfileState in
                let replacement = replacements["\(saved.applicationBundleID)|\(saved.installationID)"]
                return BrowserProfileState(applicationBundleID: replacement?.browser ?? saved.applicationBundleID,
                                    installationID: replacement?.installationID ?? saved.installationID,
                                    adapterStateVersion: saved.adapterStateVersion,
                                    launchUserDataDirectory: saved.launchUserDataDirectory,
                                    launchProfileDirectory: saved.launchProfileDirectory,
                                    browserIdentityVerified: replacement != nil || saved.browserIdentityVerified,
                                    windows: saved.windows)
            }
            desktop = SavedDesktop(formatVersion: desktop.formatVersion, id: desktop.id, name: desktop.name,
                                   createdAt: desktop.createdAt, modifiedAt: Date(), profiles: profiles, finderFolders: desktop.finderFolders,
                                   previewDocuments: desktop.previewDocuments, notes: desktop.notes,
                                   applications: desktop.applications,
                                   limitations: desktop.limitations)
            do { try store.save(desktop, replacing: true) }
            catch { show("Profile association failed", "The saved Desktop was not changed: \(error.localizedDescription)"); return }
        }
        let incomplete = attemptStore.incomplete(for: desktop.id).first
        if let incomplete {
            let recovery=NSAlert(); recovery.messageText="An earlier load was interrupted"; recovery.informativeText="Retry reconciles the earlier operation before opening anything new. Start new intentionally creates another copy."; recovery.addButton(withTitle:"Retry"); recovery.addButton(withTitle:"Start new load"); recovery.addButton(withTitle:"Cancel")
            let answer=recovery.runModal(); if answer == .alertThirdButtonReturn{return}
            Task { await load(desktop, attempt: answer == .alertFirstButtonReturn ? incomplete : LoadAttempt(desktopID:desktop.id)) }
        } else { Task { await load(desktop, attempt:LoadAttempt(desktopID:desktop.id)) } }
    }

    private func load(_ desktop: SavedDesktop, attempt original: LoadAttempt) async {
        var attempt = original; attempt.status = .running; try? attemptStore.save(attempt)
        cancellationRequested=false; activeOperationID=attempt.operationID; activeProfiles=desktop.profiles.map { ($0.installationID, $0.applicationBundleID) }; showProgress("Preparing saved content…")
        var results:[String]=[]
        var successfulProfiles = 0
        for profile in desktop.profiles {
            if cancellationRequested { results.append("Cancelled before profile \(profile.installationID.prefix(8))."); break }
            let browserName = ChromiumBrowser.displayName(for: profile.applicationBundleID)
            updateProgress("Connecting to \(browserName) profile \(profile.installationID.prefix(8))…")
            // A recently written inventory file is not proof that the extension is
            // still alive. A Chromium browser can disappear while the file remains inside the
            // freshness window, so require a round-trip before skipping launch.
            var connected = await profileIsResponsive(profile.installationID, browserBundleID: profile.applicationBundleID, timeout: 2)
            var startupToken: String?
            if !connected, let locator=profile.launchProfileDirectory {
                guard let browser = ChromiumBrowser(rawValue: profile.applicationBundleID) else {
                    results.append("Profile \(profile.installationID.prefix(8)): saved browser identity is ambiguous. Associate it with a verified live browser profile before loading."); attempt.status = .failed; continue
                }
                let executable=URL(fileURLWithPath:browser.executablePath)
                if FileManager.default.isExecutableFile(atPath:executable.path) {
                    let token = attempt.operationID.uuidString.lowercased(); startupToken = token
                    let marker = "chrome-extension://agimibdhlfgliioagkdaefkddfenhmfe/startup.html#deskriptions-restore=\(token)"
                    let process=Process(); process.executableURL=executable; process.arguments=(profile.launchUserDataDirectory.map{["--user-data-dir=\($0)"]} ?? [])+["--profile-directory=\(locator)", "--new-window", marker]
                    do { try process.run() }
                    catch { results.append("Profile \(profile.installationID.prefix(8)): \(browser.displayName) could not be launched: \(error.localizedDescription)"); attempt.status = .failed; continue }
                }
                let deadline=Date().addingTimeInterval(20)
                while Date()<deadline && !connected {
                    try? await Task.sleep(nanoseconds:500_000_000)
                    connected = await profileIsResponsive(profile.installationID, browserBundleID: profile.applicationBundleID, timeout: 2)
                }
            }
            guard connected else {
                let mapping = profile.launchProfileDirectory == nil ? "No verified launch mapping is saved." : "\(browserName) launched, but the matching extension did not connect within 20 seconds."
                results.append("Profile \(profile.installationID.prefix(8)): \(mapping) Open the intended \(browserName) profile, verify extension and bridge versions in Setup, then Retry.")
                attempt.status = .failed; continue
            }
            let windows = profile.windows.map { w in JSONValue.object(["id":.string(w.id.uuidString),"frame":rectJSON(w.frame),"tabs":.array(w.tabs.map { .object(["url":.string($0.url),"order":.number(Double($0.order)),"pinned":.bool($0.pinned),"active":.bool($0.active)]) })]) }
            var payload: [String: JSONValue] = ["attemptID":.string(attempt.attemptID.uuidString),"windows":.array(windows)]
            if let startupToken { payload["startupToken"] = .string(startupToken) }
            do { let response=try await bridge.send(.init(type:"restoreDesktop",operationID:attempt.operationID.uuidString,payload:.object(payload)),to:profile.installationID,browserBundleID:profile.applicationBundleID,timeout:30); results.append("\(browserName) profile \(profile.installationID.prefix(8)): \(response.status ?? "unknown"). Current desktop was requested; macOS does not expose a public Space identifier for independent verification."); if response.status == "complete" { successfulProfiles += 1 } else { attempt.status = response.status == "cancelled" ? .cancelled : response.status == "partial" ? .partial : response.status == "indeterminate" ? .indeterminate : .failed } }
            catch { results.append("Profile \(profile.installationID.prefix(8)): \(error.localizedDescription)"); attempt.status = successfulProfiles > 0 ? .partial : .failed }
        }
        var successfulFinder = 0
        if !cancellationRequested {
            for folder in desktop.finderFolders {
                updateProgress("Opening Finder folder \(URL(fileURLWithPath:folder.path).lastPathComponent)…")
                do {
                    let existing = try finderAdapter.inventory().first { standardized($0.path) == standardized(folder.path) }
                    if let existing { try finderAdapter.bringToFront(existing); results.append("Finder: already open, verified, and brought to the front — \(folder.path)") }
                    else { _ = try finderAdapter.restore(folder); results.append("Finder: opened and verified — \(folder.path)") }
                    successfulFinder += 1
                } catch { results.append("Finder: \(error.localizedDescription)") }
            }
        }
        var successfulPreview = 0
        if !cancellationRequested {
            for document in desktop.previewDocuments {
                updateProgress("Opening Preview document \(document.displayName)…")
                do { _ = try await previewAdapter.restore(document); results.append("Preview: opened, verified, and brought to the front — \(document.path)"); successfulPreview += 1 }
                catch { results.append("Preview: \(error.localizedDescription)") }
            }
        }
        var successfulNotes = 0
        if !cancellationRequested {
            for note in desktop.notes {
                updateProgress("Opening note \(note.displayName)…")
                do { try await notesAdapter.restore(note); results.append("Notes: opened verified note ‘\(note.displayName)’ by stable identifier."); successfulNotes += 1 }
                catch { results.append("Notes: \(error.localizedDescription)") }
            }
        }
        var successfulApplications = 0
        if !cancellationRequested {
            for application in desktop.applications {
                updateProgress("Opening \(application.displayName)…")
                switch await genericAdapter.restore(application) {
                case .success(let message): results.append(message); successfulApplications += 1
                case .failure(let error): results.append("\(application.displayName): \(error.localizedDescription)")
                }
            }
        }
        let totalUnits = desktop.profiles.count + desktop.finderFolders.count + desktop.previewDocuments.count + desktop.notes.count + desktop.applications.count
        let successfulUnits = successfulProfiles + successfulFinder + successfulPreview + successfulNotes + successfulApplications
        attempt.status = LoadAttempt.finalStatus(successfulProfiles: successfulUnits, totalProfiles: totalUnits, current: attempt.status, cancelled: cancellationRequested)
        attempt.error = results.joined(separator:"\n"); try? attemptStore.save(attempt)
        await MainActor.run {
            status.record(title: "Load details — \(desktop.name)", detail: results.joined(separator: "\n"))
            let summary: String
            switch attempt.status {
            case .complete: summary = "All \(successfulUnits) item(s) restored or activated."
            case .partial: summary = "\(successfulUnits) of \(totalUnits) item(s) completed. Open Recent Status for details."
            case .cancelled: summary = "Loading stopped. \(successfulUnits) item(s) had already completed."
            default: summary = "Loading failed. Open Recent Status for details."
            }
            status.show(title: attempt.status == .complete ? "Desktop loaded" : "Desktop load \(attempt.status.rawValue)", detail: summary, duration: attempt.status == .complete ? 5 : 9)
        }
    }

    private func profileIsResponsive(_ installationID: String, browserBundleID: String, timeout: TimeInterval) async -> Bool {
        guard await bridge.connectedProfiles().contains(where: { $0.installationID == installationID && $0.browser == browserBundleID }) else { return false }
        return (try? await bridge.send(.init(type: "freshInventory"), to: installationID, browserBundleID: browserBundleID, timeout: timeout)) != nil
    }

    private func showProgress(_ text:String){status.show(title:"Loading Desktop",detail:text,duration:30)}
    private func updateProgress(_ text:String){status.update(title:"Loading Desktop",detail:text)}
    @objc private func cancelLoad(){cancellationRequested=true;status.update(title:"Loading Desktop",detail:"Cancelling after the current step…");guard let operation=activeOperationID else{return};for profile in activeProfiles{Task{_ = try? await bridge.send(.init(type:"cancelOperation",operationID:operation.uuidString),to:profile.installationID,browserBundleID:profile.browserBundleID,timeout:5)}}}

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item=rows[row], container=NSView(frame:NSRect(x:0,y:0,width:640,height:25)), icon=NSImageView(frame:NSRect(x:CGFloat(item.indent*22),y:3,width:18,height:18)), button=NSButton(checkboxWithTitle:item.title,target:self,action:#selector(toggleRow(_:))); button.tag=row; button.allowsMixedState=true; button.frame=NSRect(x:CGFloat(item.indent*22+22),y:0,width:618-CGFloat(item.indent*22),height:25)
        icon.imageScaling = .scaleProportionallyDown
        if let bundleID = item.applicationBundleID { icon.image = applicationIcon(for: bundleID) }
        else if let dataURL = item.faviconDataURL {
            if let cached = faviconCache[dataURL] { icon.image = cached }
            else { icon.image = NSImage(systemSymbolName: "globe", accessibilityDescription: "Website"); loadFavicon(dataURL) }
        } else if case .tab = item.kind { icon.image = NSImage(systemSymbolName: "globe", accessibilityDescription: "Website") }
        else if case .unsupported = item.kind { icon.image = NSImage(systemSymbolName: "app.dashed", accessibilityDescription: "Application") }
        switch item.kind { case .unsupported: button.isEnabled = false; button.state = .off; default: button.state = item.state == .on ? .on : item.state == .mixed ? .mixed : .off }
        container.addSubview(icon); container.addSubview(button); return container
    }

    private func rebuildRows() {
        rows=[]
        for (pi,p) in profiles.enumerated(){rows.append(.init(kind:.profile(pi),title:"\(ChromiumBrowser.displayName(for:p.browser)) profile \(p.installationID.prefix(8)) — connected",indent:0,state:profileState(p),applicationBundleID:p.browser))
            for (wi,w) in p.windows.enumerated(){let a=associations[p.identityKey]?.first{$0.browserWindowID==w.extensionWindowID};let visibility=a?.nativeWindowID.flatMap{nativeWindow($0)?.onScreen} == true ? "on screen" : "visibility unconfirmed";rows.append(.init(kind:.window(pi,wi),title:"Window \(w.extensionWindowID) — \(visibility) — \(a?.status.rawValue ?? "unresolved")",indent:1,state:selection.state(for:w,profileID:p.identityKey),applicationBundleID:p.browser));for tab in w.tabs.sorted(by:{$0.index<$1.index}){rows.append(.init(kind:.tab(pi,wi,tab.id),title:"\(tab.pinned ? "Pinned — " : "")\(tab.title.isEmpty ? tab.url : tab.title)",indent:2,state:selection.contains(tabID:tab.id,profileID:p.identityKey) ? .on:.off,faviconDataURL:tab.faviconDataURL))}}
        }
        for (index,folder) in finderFolders.enumerated(){let visibility=folder.onScreen ? "on screen" : "not on screen";rows.append(.init(kind:.finderFolder(index),title:"Finder — \(URL(fileURLWithPath:folder.path).lastPathComponent) — \(visibility) — reopenable; kept open after save",indent:0,state:selectedFinderWindowIDs.contains(folder.windowID) ? .on:.off,applicationBundleID:"com.apple.finder"))}
        for (index, document) in previewDocuments.enumerated() { let visibility = document.onScreen ? "on screen" : "not on screen"; rows.append(.init(kind: .previewDocument(index), title: "Preview — \(document.displayName) — \(visibility) — exact file", indent: 0, state: selectedPreviewPaths.contains(document.path) ? .on : .off, applicationBundleID: PreviewAdapter.bundleIdentifier)) }
        for (index, note) in noteObservations.enumerated() { let visibility = note.onScreen ? "on screen" : "not on screen", identity = String(note.identifier.suffix(8)); rows.append(.init(kind: .note(index), title: "Notes — \(note.displayName) [\(identity)] — \(visibility) — selected note", indent: 0, state: selectedNoteIDs.contains(note.identifier) ? .on : .off, applicationBundleID: NotesAdapter.bundleIdentifier)) }
        for (index, application) in genericApplications.enumerated() {
            let visibility = application.hasOnScreenWindow ? "on screen" : "not on screen"
            rows.append(.init(kind: .genericApplication(index), title: "\(application.displayName) — \(visibility) — Opens application; window contents are not restored. Kept open after save.", indent: 0, state: selectedGenericBundleIDs.contains(application.bundleIdentifier) ? .on : .off, applicationBundleID: application.bundleIdentifier))
        }
    }
    private func profileState(_ p:ExtensionHello)->SelectionState{let states=p.windows.map{selection.state(for:$0,profileID:p.identityKey)};return states.allSatisfy{$0 == .off} ? .off : states.allSatisfy{$0 == .on} ? .on:.mixed}
    private func buildAssociations(_ ps:[ExtensionHello])->[String:[WindowAssociation]] {
        let native = allNativeWindows()
        return Dictionary(uniqueKeysWithValues: ps.map { profile in
            let browserWindows = native.filter { NSRunningApplication(processIdentifier: $0.ownerPID)?.bundleIdentifier == profile.browser }
            return (profile.identityKey, WindowMatcher.associate(browser: profile.windows, native: browserWindows))
        })
    }
    private func allNativeWindows()->[NativeWindow]{(CGWindowListCopyWindowInfo([.optionAll,.excludeDesktopElements],kCGNullWindowID) as? [[String:Any]] ?? []).compactMap{r in guard let id=r[kCGWindowNumber as String] as? UInt32,let pid=r[kCGWindowOwnerPID as String] as? Int32,let owner=r[kCGWindowOwnerName as String] as? String,let d=r[kCGWindowBounds as String] as? NSDictionary,let f=CGRect(dictionaryRepresentation:d as CFDictionary),(r[kCGWindowLayer as String] as? Int)==0,(r[kCGWindowAlpha as String] as? Double ?? 1)>0,f.width>=120,f.height>=80 else{return nil};return NativeWindow(windowID:id,ownerPID:pid,ownerName:owner,title:r[kCGWindowName as String] as? String ?? "",bounds:.init(x:f.minX,y:f.minY,width:f.width,height:f.height),onScreen:r[kCGWindowIsOnscreen as String] as? Bool ?? false)}}
    private func nativeWindow(_ id:UInt32)->NativeWindow?{allNativeWindows().first{$0.windowID==id}}
    private func desktopCounter() -> Int {
        nameCounter.current(existingDesktops: store.list().desktops)
    }
    private func advanceDesktopCounter() {
        nameCounter.advance(existingDesktops: store.list().desktops)
    }
    private func defaultName() -> String {
        let now = Date()
        let time = DateFormatter()
        time.locale = .current
        time.timeZone = .current
        time.dateFormat = "HH:mm"
        let date = DateFormatter()
        date.locale = .current
        date.timeZone = .current
        date.dateFormat = "d MMM yyyy"
        return "Desktop \(desktopCounter()) -- \(time.string(from: now)) on \(date.string(from: now))"
    }
    private func standardized(_ path:String)->String{URL(fileURLWithPath:path).standardizedFileURL.path}
    private func rectJSON(_ r:Rect)->JSONValue{.object(["x":.number(r.x),"y":.number(r.y),"width":.number(r.width),"height":.number(r.height)])}
    private func show(_ title:String,_ text:String){let a=NSAlert();a.messageText=title;a.informativeText=text;a.runModal()}
    private func applicationIcon(for bundleID: String) -> NSImage {
        if let cached = applicationIconCache[bundleID] { return cached }
        let image = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSImage(systemSymbolName: "app.dashed", accessibilityDescription: "Application")!
        image.size = NSSize(width: 18, height: 18); applicationIconCache[bundleID] = image; return image
    }
    private func loadFavicon(_ dataURL: String) {
        guard !faviconLoads.contains(dataURL) else { return }; faviconLoads.insert(dataURL)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let encoded = dataURL.split(separator: ",", maxSplits: 1).last.map(String.init)
            let decoded: Data? = encoded.flatMap { Data(base64Encoded: $0) }
            let image: NSImage? = decoded.flatMap { NSImage(data: $0) }
            DispatchQueue.main.async { guard let self else { return }; self.faviconLoads.remove(dataURL); if let image { image.size = NSSize(width: 16, height: 16); self.faviconCache[dataURL] = image; self.table?.reloadData() } }
        }
    }
    private struct Row { enum Kind{case profile(Int),window(Int,Int),tab(Int,Int,Int),finderFolder(Int),previewDocument(Int),note(Int),genericApplication(Int),unsupported};let kind:Kind,title:String,indent:Int,state:SelectionState;var applicationBundleID:String?=nil;var faviconDataURL:String?=nil }
}

private extension Result where Failure: Error {
    var failureDescription: String? { if case .failure(let error) = self { return error.localizedDescription }; return nil }
}
