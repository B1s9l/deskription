import AppKit
import ApplicationServices
import DeskriptionsCore

typealias PreviewDocumentObservation = DocumentObservation

final class PreviewAdapter: DocumentDiscoveryAdapter {
    static let bundleIdentifier = "com.apple.Preview"
    let applicationBundleID = PreviewAdapter.bundleIdentifier
    let applicationDisplayName = "Preview"
    enum AdapterError: LocalizedError {
        case accessibilityRequired, identityUnavailable, unavailable(String), verificationFailed(String), automation(String)
        var errorDescription: String? {
            switch self {
            case .accessibilityRequired: return "Preview document identification requires Accessibility access. Enable Deskriptions in Privacy & Security → Accessibility, then reopen Save Desktop."
            case .identityUnavailable: return "Preview is open, but it did not expose an exact AXDocument file URL. Deskriptions will offer Preview as application-only; document contents cannot be restored precisely."
            case .unavailable(let path): return "The saved Preview document is unavailable: \(path)"
            case .verificationFailed(let path): return "Preview did not expose a verified window for: \(path)"
            case .automation(let message): return "Preview integration failed: \(message)"
            }
        }
    }

    func inventory() throws -> [PreviewDocumentObservation] {
        guard AXIsProcessTrusted() else { throw AdapterError.accessibilityRequired }
        let applications = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier).filter { !$0.isTerminated }
        guard !applications.isEmpty else { return [] }
        var sawWindow = false
        let observations = applications.flatMap { app -> [PreviewDocumentObservation] in
            let application = AXUIElementCreateApplication(app.processIdentifier)
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &value) == .success,
                  let windows = value as? [AXUIElement] else { return [] }
            if !windows.isEmpty { sawWindow = true }
            let native = nativeWindows(pid: app.processIdentifier)
            return windows.compactMap { window -> PreviewDocumentObservation? in
            guard let document = attribute(kAXDocumentAttribute, of: window), let url = documentURL(document), url.isFileURL else { return nil }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue,
                  FileManager.default.isReadableFile(atPath: url.path) else { return nil }
            let minimized = boolAttribute(kAXMinimizedAttribute, of: window) ?? false
            let frame = windowFrame(window)
            let onScreen = !app.isHidden && !minimized && frame.map { candidate in native.contains { approximatelyEqual($0, candidate) && $0.onScreen } } == true
            return PreviewDocumentObservation(applicationBundleID: Self.bundleIdentifier, applicationBundlePath: app.bundleURL?.path, path: url.standardizedFileURL.path, displayName: url.lastPathComponent, onScreen: onScreen, identityMetadata: ["discovery": "AXDocument"])
            }
        }
        let unique = observations.reduce(into: [PreviewDocumentObservation]()) { values, item in if !values.contains(where: { $0.path == item.path }) { values.append(item) } }
        if sawWindow && unique.isEmpty { throw AdapterError.identityUnavailable }
        return unique
    }

    /// Preview may publish its window before `AXWindows`/`AXDocument` is ready.
    /// A bounded retry prevents a transient launch or tab transition from being
    /// misreported as application-only restoration.
    func inventoryWithRetry() async throws -> [PreviewDocumentObservation] {
        try await inventoryWithRetry(timeout: .seconds(2))
    }

    func inventoryWithRetry(timeout: Duration) async throws -> [PreviewDocumentObservation] {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var lastError: Error?
        repeat {
            do {
                let documents = try inventory()
                if !documents.isEmpty || NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier).isEmpty { return documents }
            } catch AdapterError.accessibilityRequired {
                throw AdapterError.accessibilityRequired
            } catch {
                lastError = error
            }
            try? await Task.sleep(for: .milliseconds(200))
        } while clock.now < deadline
        if let lastError { throw lastError }
        return try inventory()
    }

    func bringToFront(path: String) throws { try raise(path: path) }

    func observation(forPath path: String) async throws -> DocumentObservation? {
        guard AXIsProcessTrusted() else { throw AdapterError.accessibilityRequired }
        guard let (app, _) = matchingWindow(path: path) else { return nil }
        let normalized = URL(fileURLWithPath: path).standardizedFileURL
        return DocumentObservation(applicationBundleID: Self.bundleIdentifier,
                                   applicationBundlePath: app.bundleURL?.path,
                                   path: normalized.path,
                                   displayName: normalized.lastPathComponent,
                                   onScreen: !app.isHidden,
                                   identityMetadata: ["discovery": "AXDocument-targeted"])
    }

    func restore(_ saved: SavedPreviewDocument) async throws -> PreviewDocumentObservation {
        try await DocumentRestorer().restore(SavedDocumentReference(saved), using: self)
    }

    func close(_ saved: SavedPreviewDocument) async throws -> Bool { try await close(path: saved.path) }

    func close(path: String) async throws -> Bool {
        guard AXIsProcessTrusted(), let (_, window) = matchingWindow(path: path) else { return false }
        var buttonValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXCloseButtonAttribute as CFString, &buttonValue) == .success,
              let button = buttonValue as! AXUIElement? else { return false }
        guard AXUIElementPerformAction(button, kAXPressAction as CFString) == .success else { return false }
        try? await Task.sleep(for: .milliseconds(750))
        // If an unsaved-change prompt or user cancellation keeps the document
        // present, report that it stayed open rather than bypassing the prompt.
        return matchingWindow(path: path) == nil
    }

    private func raise(path: String) throws {
        guard let (app, window) = matchingWindow(path: path),
              app.activate(options: [.activateAllWindows]),
              AXUIElementPerformAction(window, kAXRaiseAction as CFString) == .success else { throw AdapterError.verificationFailed(path) }
    }
    private func matchingWindow(path: String) -> (NSRunningApplication, AXUIElement)? {
        let matches = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier).compactMap { app -> (NSRunningApplication, AXUIElement)? in
            guard !app.isTerminated, let window = matchingWindow(path: path, pid: app.processIdentifier) else { return nil }
            return (app, window)
        }
        return matches.count == 1 ? matches[0] : nil
    }
    private func matchingWindow(path: String, pid: pid_t) -> AXUIElement? {
        let application = AXUIElementCreateApplication(pid); var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &value) == .success, let windows = value as? [AXUIElement] else { return nil }
        let wanted = URL(fileURLWithPath: path).standardizedFileURL.path
        let matches = windows.filter { attribute(kAXDocumentAttribute, of: $0).flatMap(documentURL)?.standardizedFileURL.path == wanted }
        return matches.count == 1 ? matches[0] : nil
    }
    private func documentURL(_ value: CFTypeRef) -> URL? {
        if CFGetTypeID(value) == CFURLGetTypeID() { return value as? URL }
        guard let string = value as? String else { return nil }
        if string.hasPrefix("file:") { return URL(string: string) }
        return string.hasPrefix("/") ? URL(fileURLWithPath: string) : nil
    }
    private func attribute(_ name: String, of element: AXUIElement) -> CFTypeRef? { var value: CFTypeRef?; return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil }
    private func stringAttribute(_ name: String, of element: AXUIElement) -> String? { var value: CFTypeRef?; return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value as? String : nil }
    private func boolAttribute(_ name: String, of element: AXUIElement) -> Bool? { var value: CFTypeRef?; return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value as? Bool : nil }
    private func windowFrame(_ window: AXUIElement) -> CGRect? {
        var p: CFTypeRef?, s: CFTypeRef?; var point = CGPoint.zero, size = CGSize.zero
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &p) == .success, AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &s) == .success,
              AXValueGetValue(p as! AXValue, .cgPoint, &point), AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }
    private func nativeWindows(pid: pid_t) -> [(frame: CGRect, onScreen: Bool)] { (CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []).compactMap { row in guard (row[kCGWindowOwnerPID as String] as? Int32) == pid, let dictionary = row[kCGWindowBounds as String] as? NSDictionary, let frame = CGRect(dictionaryRepresentation: dictionary as CFDictionary), (row[kCGWindowLayer as String] as? Int) == 0 else { return nil }; return (frame, row[kCGWindowIsOnscreen as String] as? Bool ?? false) } }
    private func approximatelyEqual(_ lhs: (frame: CGRect, onScreen: Bool), _ rhs: CGRect) -> Bool { abs(lhs.frame.minX-rhs.minX)<5 && abs(lhs.frame.minY-rhs.minY)<5 && abs(lhs.frame.width-rhs.width)<5 && abs(lhs.frame.height-rhs.height)<5 }
}
