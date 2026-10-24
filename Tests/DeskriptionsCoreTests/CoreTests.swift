import XCTest
@testable import DeskriptionsCore

final class CoreTests: XCTestCase {
    func testAfterSavePolicyAndSafeDismissal() {
        XCTAssertEqual(AfterSavePolicy.decision(for: .keepOpen), .keepOpen)
        XCTAssertEqual(AfterSavePolicy.decision(for: .closeSupportedContent), .closeSupportedContent)
        XCTAssertEqual(AfterSavePolicy.decision(for: .askEveryTime), .prompt)
        XCTAssertEqual(AfterSavePolicy.decision(after: .dismissed), .keepOpen)
        XCTAssertEqual(AfterSavePolicy.decision(after: .keepOpen), .keepOpen)
        XCTAssertEqual(AfterSavePolicy.decision(after: .closeSupportedContent), .closeSupportedContent)
        XCTAssertNil(AfterSavePolicy.decision(persistenceSucceeded: false, behavior: .closeSupportedContent))
        XCTAssertEqual(AfterSavePolicy.decision(persistenceSucceeded: true, behavior: .closeSupportedContent), .closeSupportedContent)
    }

    func testAfterSavePreferenceDefaultsAndPersists() throws {
        let suite = "DeskriptionsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let store = AfterSavePreferenceStore(defaults: defaults)
        XCTAssertEqual(store.behavior(hasExistingDesktops: false), .askEveryTime)
        store.set(.keepOpen)
        XCTAssertEqual(store.behavior(hasExistingDesktops: true), .keepOpen)
        defaults.removeObject(forKey: AfterSavePreferenceStore.key)
        XCTAssertEqual(store.behavior(hasExistingDesktops: true), .closeSupportedContent)
    }

    func testRetentionPreferencesDefaultClampAndPersistence() throws {
        let suite = "DeskriptionsRetentionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = DesktopRetentionPreferences(defaults: defaults)
        XCTAssertFalse(preferences.isEnabled)
        XCTAssertEqual(preferences.limit, 10)
        preferences.setEnabled(true); preferences.setLimit(75)
        XCTAssertTrue(preferences.isEnabled); XCTAssertEqual(preferences.limit, 50)
        preferences.setLimit(0); XCTAssertEqual(preferences.limit, 1)
    }

    func testDesktopNameCounterInitializesFromExistingNamesAndPersists() throws {
        let suite = "DeskriptionsNameCounterTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let counter = DesktopNameCounter(defaults: defaults)
        let existing = [
            SavedDesktop(name: "Desktop 4 -- 12:00 on 1 Jan 2026", profiles: [], limitations: []),
            SavedDesktop(name: "Custom", profiles: [], limitations: [])
        ]
        XCTAssertEqual(counter.current(existingDesktops: existing), 5)
        counter.advance(existingDesktops: existing)
        XCTAssertEqual(counter.current(existingDesktops: []), 6)
        defaults.set(0, forKey: DesktopNameCounter.key)
        XCTAssertEqual(counter.current(existingDesktops: []), 1)
    }

    func testRetentionDeletesOldestAndProtectsNewDesktop() throws {
        let store = temporaryStore(), base = Date(timeIntervalSince1970: 1_000)
        let desktops = (0..<5).map { index in
            SavedDesktop(id: UUID(), name: "Desktop \(index)", createdAt: base.addingTimeInterval(Double(index)), modifiedAt: base, profiles: [], limitations: [])
        }
        for desktop in desktops { try store.save(desktop) }
        let result = store.applyRetention(limit: 2, protecting: desktops.last?.id)
        XCTAssertEqual(result, DesktopDeletionResult(requested: 3, deleted: 3, failures: []))
        XCTAssertEqual(Set(store.list().desktops.map(\.id)), Set(desktops.suffix(2).map(\.id)))
    }

    func testDeleteAllUsesIsolatedStoreAndAcceptsEmptyInventory() throws {
        let store = temporaryStore()
        try store.save(sampleDesktop()); try store.save(sampleDesktop())
        XCTAssertEqual(try store.deleteAll(), 2)
        XCTAssertTrue(store.list().desktops.isEmpty)
        XCTAssertEqual(try store.deleteAll(), 0)
        try store.save(sampleDesktop())
        XCTAssertEqual(store.list().desktops.count, 1)
    }

    func testDesktopPresentationGroupsProfilesAndCountsWithoutDuplicates() {
        let tab = SavedTab(url: "https://example.com/very/long/path", title: String(repeating: "Long title ", count: 20), pinned: false, active: true, order: 0, faviconDataURL: "data:image/png;base64,dGVzdA==")
        let window = SavedWindow(frame: .init(x: 0, y: 0, width: 800, height: 600), state: "normal", tabs: [tab])
        let profiles = ["Personal", "Work"].map { BrowserProfileState(applicationBundleID: ChromiumBrowser.chrome.rawValue, installationID: $0, adapterStateVersion: 1, launchProfileDirectory: $0, windows: [window]) }
        let finder = SavedFinderFolder(sourceWindowID: 1, path: "/tmp/Disposable Folder", frame: .init(x: 0, y: 0, width: 500, height: 400))
        let desktop = SavedDesktop(name: "Mixed", profiles: profiles, finderFolders: [finder], applications: [SavedApplication(bundleIdentifier: ChromiumBrowser.chrome.rawValue, displayName: "Duplicate Chrome"), SavedApplication(bundleIdentifier: "com.example.Editor", displayName: "Editor")], limitations: [])
        XCTAssertEqual(DesktopPresentation.summary(for: desktop), DesktopContentSummary(applicationCount: 3, browserTabCount: 2, folderCount: 1))
        let hierarchy = DesktopPresentation.hierarchy(for: desktop, browserName: ChromiumBrowser.displayName(for:))
        XCTAssertEqual(hierarchy.filter { $0.bundleIdentifier == ChromiumBrowser.chrome.rawValue }.count, 1)
        XCTAssertEqual(hierarchy.first { $0.bundleIdentifier == ChromiumBrowser.chrome.rawValue }?.children.count, 2)
        XCTAssertEqual(hierarchy.first { $0.bundleIdentifier == ChromiumBrowser.chrome.rawValue }?.children.map(\.kind), [.window, .window])
        XCTAssertEqual(hierarchy.first { $0.bundleIdentifier == ChromiumBrowser.chrome.rawValue }?.children.first?.subtitle, "Profile: Personal · 1 tab")
        XCTAssertEqual(hierarchy.first { $0.bundleIdentifier == ChromiumBrowser.chrome.rawValue }?.children.first?.children.first?.title, tab.title)
        XCTAssertEqual(hierarchy.first { $0.bundleIdentifier == ChromiumBrowser.chrome.rawValue }?.children.first?.children.first?.faviconDataURL, tab.faviconDataURL)
        let unnamed = BrowserProfileState(applicationBundleID: ChromiumBrowser.brave.rawValue, installationID: "1234567890abcdef", adapterStateVersion: 1, launchProfileDirectory: nil, windows: [window])
        let unnamedHierarchy = DesktopPresentation.hierarchy(for: SavedDesktop(name: "Unnamed", profiles: [unnamed], limitations: []), browserName: ChromiumBrowser.displayName(for:))
        XCTAssertEqual(unnamedHierarchy.first?.children.first?.subtitle, "Profile: 12345678 · 1 tab")
    }

    func testEmptyDesktopPresentationAndSafeCloseExcludesUnsupportedContent() {
        let empty = SavedDesktop(name: "Empty", profiles: [], limitations: [])
        XCTAssertEqual(DesktopPresentation.hierarchy(for: empty, browserName: { $0 }).first?.kind, .empty)
        let folder = SavedFinderFolder(sourceWindowID: 1, path: "/tmp/folder", frame: .init(x: 0, y: 0, width: 1, height: 1))
        let mixed = SavedDesktop(name: "Unsupported", profiles: [], finderFolders: [folder], applications: [SavedApplication(bundleIdentifier: "com.example.App", displayName: "App")], limitations: [])
        XCTAssertEqual(SafeClosePlan.make(for: mixed), SafeClosePlan(browserProfileKeys: [], unsupportedFolderCount: 1, unsupportedApplicationCount: 1))
        XCTAssertTrue(ClosureResultSummary(attempted: 2, completed: 1, failedOrCancelled: 1).isPartial)
    }

    func testChromiumProfilesAreNamespacedByVerifiedBrowser() {
        let chrome = ExtensionHello(installationID: "same", sessionID: "session", browser: ChromiumBrowser.chrome.rawValue, capabilities: [], windows: [])
        let brave = ExtensionHello(installationID: "same", sessionID: "session", browser: ChromiumBrowser.brave.rawValue, capabilities: [], windows: [])
        XCTAssertNotEqual(chrome.identityKey, brave.identityKey)
        XCTAssertEqual(ChromiumBrowser.displayName(for: brave.browser), "Brave Browser")
    }

    func testLegacyBrowserProfileRequiresVerifiedReassociation() throws {
        let json = """
        {"applicationBundleID":"com.google.Chrome","installationID":"legacy","adapterStateVersion":1,"launchProfileDirectory":"Default","windows":[]}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(BrowserProfileState.self, from: json)
        XCTAssertFalse(decoded.browserIdentityVerified)
    }
    func testFinderFolderRoundTripAndLegacyDefault() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let store = DesktopStore(directory: directory)
        let folder = SavedFinderFolder(sourceWindowID: 42, path: "/tmp/deskriptions-finder-test", frame: .init(x: 10, y: 20, width: 700, height: 500))
        let desktop = SavedDesktop(name: "Finder Desktop", profiles: [], finderFolders: [folder], limitations: [])
        try store.save(desktop)
        XCTAssertEqual(try store.load(desktop.id).finderFolders, [folder])
        XCTAssertEqual(try store.load(desktop.id).finderFolders.first?.applicationBundleID, "com.apple.finder")
        XCTAssertEqual(try store.load(desktop.id).windowCount, 1)
    }
    func testApplicationFallbackSelectionAndDeduplication() {
        let apps = [
            SavedApplication(bundleIdentifier: "com.example.editor", displayName: "Editor", savedBundlePath: "/Applications/Editor.app"),
            SavedApplication(bundleIdentifier: "com.example.editor", displayName: "Editor Duplicate"),
            SavedApplication(bundleIdentifier: "com.example.chat", displayName: "Chat")
        ]
        XCTAssertEqual(ApplicationFallback.deduplicated(apps).map(\.bundleIdentifier), ["com.example.chat", "com.example.editor"])
        XCTAssertEqual(ApplicationFallback.initialSelection(visibility: ["visible": true, "hidden": false], selectAll: false), ["visible"])
        XCTAssertEqual(ApplicationFallback.initialSelection(visibility: ["visible": true, "hidden": false], selectAll: true), ["visible", "hidden"])
    }
    func testSavedApplicationRoundTripAndLegacyDefault() throws {
        let store = temporaryStore()
        let app = SavedApplication(bundleIdentifier: "com.example.app", displayName: "Example", savedBundlePath: "/Applications/Example.app")
        let desktop = SavedDesktop(name: "Application Desktop", profiles: [], applications: [app], limitations: [])
        try store.save(desktop)
        XCTAssertEqual(try store.load(desktop.id).applications, [app])
        let url = store.url(for: desktop.id)
        var object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        object.removeValue(forKey: "applications")
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        XCTAssertEqual(try store.load(desktop.id).applications, [])
    }
    func testNativeIntegrationRoundTripAndLegacyDefaults() throws {
        let store = temporaryStore()
        let preview = SavedPreviewDocument(path: "/tmp/test.pdf", displayName: "test.pdf")
        let note = SavedNote(noteIdentifier: "x-coredata://stable-note", displayName: "Disposable Note")
        let desktop = SavedDesktop(name: "Native", profiles: [], previewDocuments: [preview], notes: [note], limitations: [])
        try store.save(desktop)
        let loaded = try store.load(desktop.id)
        XCTAssertEqual(loaded.previewDocuments, [preview]); XCTAssertEqual(loaded.notes, [note]); XCTAssertEqual(loaded.windowCount, 2)
        let hierarchy = DesktopPresentation.hierarchy(for: loaded, browserName: { $0 })
        XCTAssertEqual(hierarchy.map(\.bundleIdentifier), ["com.apple.Preview", "com.apple.Notes"])

        let url = store.url(for: desktop.id)
        var object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        object.removeValue(forKey: "previewDocuments"); object.removeValue(forKey: "notes")
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        let legacy = try store.load(desktop.id)
        XCTAssertTrue(legacy.previewDocuments.isEmpty); XCTAssertTrue(legacy.notes.isEmpty)
    }
    private func temporaryStore() -> DesktopStore {
        DesktopStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("deskriptions-tests-\(UUID().uuidString)"))
    }
    private func sampleDesktop(id: UUID = UUID()) -> SavedDesktop {
        SavedDesktop(id: id, name: "Desktop — Test", profiles: [.init(applicationBundleID: "com.google.Chrome", installationID: "profile-a", adapterStateVersion: 1, launchUserDataDirectory: "/tmp/disposable-chrome", launchProfileDirectory: "Profile 1", windows: [.init(sourceExtensionWindowID: 4, verifiedNativeWindowID: 9, frame: .init(x: 1, y: 2, width: 800, height: 600), state: "normal", tabs: [.init(sourceTabID: 7, url: "https://example.com", title: "Example", pinned: true, active: true, order: 0)])])], limitations: ["test"])
    }
    func testUniqueGeometryMatchesWithoutTitles() {
        let b = BrowserWindow(extensionWindowID: 7, focused: false, state: "normal", bounds: .init(x: 1, y: 2, width: 800, height: 600), tabs: [])
        let n = NativeWindow(windowID: 42, ownerPID: 1, ownerName: "Chrome", title: "same", bounds: .init(x: 2, y: 2, width: 800, height: 600), onScreen: true)
        XCTAssertEqual(WindowMatcher.associate(browser: [b], native: [n]).first?.nativeWindowID, 42)
    }
    func testIdenticalWindowsAreAmbiguous() {
        let r = Rect(x: 0, y: 0, width: 800, height: 600)
        let b = BrowserWindow(extensionWindowID: 7, focused: false, state: "normal", bounds: r, tabs: [])
        let ns = [1, 2].map { NativeWindow(windowID: UInt32($0), ownerPID: 1, ownerName: "Chrome", title: "identical", bounds: r, onScreen: true) }
        let match = WindowMatcher.associate(browser: [b], native: ns).first
        XCTAssertEqual(match?.status, .ambiguous); XCTAssertNil(match?.nativeWindowID)
    }
    func testNoCandidateIsUnresolved() {
        let b = BrowserWindow(extensionWindowID: 9, focused: false, state: "normal", bounds: .init(x: 0, y: 0, width: 1, height: 1), tabs: [])
        XCTAssertEqual(WindowMatcher.associate(browser: [b], native: []).first?.status, .unresolved)
    }
    func testLedgerDeduplicatesCompletedAndInflight() async {
        let ledger = OperationLedger()
        let first = await ledger.begin("op")
        let second = await ledger.begin("op")
        XCTAssertNil(first); XCTAssertEqual(second, "in_progress")
        await ledger.finish("op", result: "window-4")
        let third = await ledger.begin("op")
        XCTAssertEqual(third, "window-4")
    }

    func testDesktopRoundTripPreservesIdentityAndDuplicates() throws {
        let store = temporaryStore(), id = UUID()
        var desktop = sampleDesktop(id: id)
        let duplicate = desktop.profiles[0].windows[0].tabs[0]
        let window = SavedWindow(frame: .init(x: 5, y: 5, width: 400, height: 300), state: "normal", tabs: [duplicate])
        desktop = SavedDesktop(id: id, name: desktop.name, profiles: [.init(applicationBundleID: "com.google.Chrome", installationID: "profile-a", adapterStateVersion: 1, launchUserDataDirectory: "/tmp/disposable-chrome", launchProfileDirectory: "Profile 1", windows: desktop.profiles[0].windows + [window])], limitations: desktop.limitations)
        try store.save(desktop)
        let loaded = try store.load(id)
        XCTAssertEqual(loaded.id, id); XCTAssertEqual(loaded.windowCount, 2); XCTAssertEqual(loaded.tabCount, 2)
        XCTAssertEqual(loaded.profiles[0].launchUserDataDirectory, "/tmp/disposable-chrome")
    }

    func testStoreDoesNotOverwriteWithoutExplicitReplace() throws {
        let store = temporaryStore(), desktop = sampleDesktop()
        try store.save(desktop)
        XCTAssertThrowsError(try store.save(desktop)) { XCTAssertEqual($0 as? DesktopStoreError, .duplicateIdentifier) }
    }

    func testCorruptRecordIsIsolated() throws {
        let store = temporaryStore(); try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: store.directory.appendingPathComponent("broken.json"))
        try store.save(sampleDesktop())
        let result = store.list()
        XCTAssertEqual(result.desktops.count, 1); XCTAssertEqual(result.errors.count, 1)
    }

    func testUnsupportedFormatIsNotDecoded() throws {
        let store = temporaryStore(); try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        try Data("{\"formatVersion\":999}".utf8).write(to: store.directory.appendingPathComponent("future.json"))
        XCTAssertThrowsError(try store.load(UUID()))
        XCTAssertEqual(store.list().errors.count, 1)
    }

    func testTriStateSelection() {
        let tabs = [TabRecord(id: 1, title: "A", url: "a", active: true), TabRecord(id: 2, title: "B", url: "b", active: false)]
        let window = BrowserWindow(extensionWindowID: 3, focused: true, state: "normal", bounds: .init(x: 0, y: 0, width: 1, height: 1), tabs: tabs)
        var selection = DesktopSelection()
        XCTAssertEqual(selection.state(for: window, profileID: "a"), .off)
        selection.set(tabID: 1, profileID: "a", selected: true); XCTAssertEqual(selection.state(for: window, profileID: "a"), .mixed)
        selection.set(window: window, profileID: "a", selected: true); XCTAssertEqual(selection.state(for: window, profileID: "a"), .on)
        selection.set(window: window, profileID: "a", selected: false); XCTAssertEqual(selection.state(for: window, profileID: "a"), .off)
        selection.set(tabID: 1, profileID: "b", selected: true); XCTAssertFalse(selection.contains(tabID: 1, profileID: "a"))
    }

    func testAdapterCommandRoundTrip() throws {
        let command = AdapterCommand(type: "restoreDesktop", requestID: "request", operationID: "operation", payload: .object(["tabs": .array([.string("https://example.com")])]))
        XCTAssertEqual(try JSONDecoder().decode(AdapterCommand.self, from: JSONEncoder().encode(command)).payload, command.payload)
    }

    func testIncompleteAttemptPersistsForRetry() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("deskriptions-attempts-\(UUID().uuidString)")
        let store = LoadAttemptStore(directory: directory), desktopID = UUID()
        var attempt = LoadAttempt(desktopID: desktopID); attempt.status = .indeterminate
        try store.save(attempt)
        XCTAssertEqual(store.incomplete(for: desktopID).first?.operationID, attempt.operationID)
        attempt.status = .complete; try store.save(attempt)
        XCTAssertTrue(store.incomplete(for: desktopID).isEmpty)
    }

    func testDiagnosticExportContainsCountsButNoPrivateContent() throws {
        let store = temporaryStore(), desktop = sampleDesktop()
        try store.save(desktop)
        let attempts = LoadAttemptStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("deskriptions-diagnostics-attempts-\(UUID().uuidString)"))
        var attempt = LoadAttempt(desktopID: desktop.id); attempt.status = .partial; try attempts.save(attempt)
        let profile = ExtensionHello(installationID: "secret-profile-id", sessionID: "secret-session", browser: "com.google.Chrome", capabilities: [], windows: [])
        let report = DiagnosticExporter.makeReport(appVersion: "0.4.0", desktopStore: store, attemptStore: attempts, connectedProfiles: [profile], operatingSystem: "Test OS")
        let text = String(decoding: try DiagnosticExporter.encode(report), as: UTF8.self)
        XCTAssertEqual(report.savedDesktopCount, 1); XCTAssertEqual(report.savedTabCount, 1)
        XCTAssertEqual(report.operationStatusCounts["partial"], 1)
        XCTAssertFalse(text.contains("https://example.com")); XCTAssertFalse(text.contains("Desktop — Test"))
        XCTAssertFalse(text.contains("secret-profile-id")); XCTAssertFalse(text.contains("secret-session"))
    }

    func testLoadStatusDoesNotReportCompleteForDisconnectedProfiles() {
        XCTAssertEqual(LoadAttempt.finalStatus(successfulProfiles: 0, totalProfiles: 1, current: .failed, cancelled: false), .failed)
        XCTAssertEqual(LoadAttempt.finalStatus(successfulProfiles: 1, totalProfiles: 2, current: .failed, cancelled: false), .partial)
        XCTAssertEqual(LoadAttempt.finalStatus(successfulProfiles: 2, totalProfiles: 2, current: .running, cancelled: false), .complete)
        XCTAssertEqual(LoadAttempt.finalStatus(successfulProfiles: 1, totalProfiles: 2, current: .running, cancelled: true), .cancelled)
    }

    func testBridgeDeduplicatesOneConnectionSession() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("deskriptions-bridge-dedup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        let old = ExtensionHello(installationID: "race-old", sessionID: "same-session", browser: "com.google.Chrome", capabilities: ["inventory.windows", "inventory.fresh"], windows: [], adapterVersion: "0.4.1")
        let current = ExtensionHello(installationID: "stable", sessionID: "same-session", browser: "com.google.Chrome", capabilities: ["inventory.windows", "inventory.fresh"], windows: [], adapterVersion: "0.4.2")
        let oldURL = root.appendingPathComponent("profile-race-old.json"), currentURL = root.appendingPathComponent("profile-stable.json")
        try encoder.encode(old).write(to: oldURL); try encoder.encode(current).write(to: currentURL)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-1)], ofItemAtPath: oldURL.path)
        let profiles = await FileAdapterBridge(root: root).connectedProfiles()
        XCTAssertEqual(profiles.count, 1); XCTAssertEqual(profiles.first?.installationID, "stable")
    }

    func testBridgeRejectsBrowserIdentityBasedOnlyOnManifestAlias() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("deskriptions-bridge-browser-proof-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let unverified = ExtensionHello(installationID: "same", sessionID: "session", browser: ChromiumBrowser.chrome.rawValue, capabilities: ["inventory.windows", "inventory.fresh"], windows: [], adapterVersion: "0.8.0", browserIdentitySource: "native-host-registration-v1")
        try JSONEncoder().encode(unverified).write(to: root.appendingPathComponent("profile-unverified.json"))
        let profiles = await FileAdapterBridge(root: root).connectedProfiles()
        XCTAssertTrue(profiles.isEmpty)
    }

    func testTimedOutCommandCannotRunAfterReconnect() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("deskriptions-bridge-timeout-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let hello = ExtensionHello(installationID: "stale-profile", sessionID: "dead-session", browser: "com.google.Chrome", capabilities: ["inventory.windows", "inventory.fresh"], windows: [], adapterVersion: "0.5.0")
        try JSONEncoder().encode(hello).write(to: root.appendingPathComponent("profile-stale-profile.json"))
        let bridge = FileAdapterBridge(root: root)
        do {
            _ = try await bridge.send(.init(type: "restoreDesktop", requestID: "must-not-run-later"), to: hello.installationID, timeout: 0.2)
            XCTFail("Expected timeout")
        } catch {
            XCTAssertEqual(error as? AdapterBridgeError, .timeout)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("command-stale-profile.json").path))
    }

    func testIncompleteDiagnosticRegistrationIsNotALiveChromeProfile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("deskriptions-bridge-incomplete-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let synthetic = ExtensionHello(installationID: "diagnostic", sessionID: "test", browser: "com.google.Chrome", capabilities: [], windows: [])
        try JSONEncoder().encode(synthetic).write(to: root.appendingPathComponent("profile-diagnostic.json"))
        let profiles = await FileAdapterBridge(root: root).connectedProfiles()
        XCTAssertTrue(profiles.isEmpty)
    }
}
