import AppKit
import ApplicationServices
import DeskriptionsCore

struct PreviewDocumentObservation: Equatable {
    let path: String
    let displayName: String
    let onScreen: Bool
}

@MainActor
final class PreviewAdapter {
    static let bundleIdentifier = "com.apple.Preview"
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
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier).first else { return [] }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return [] }
        let native = nativeWindows(pid: app.processIdentifier)
        let observations: [PreviewDocumentObservation] = windows.compactMap { window -> PreviewDocumentObservation? in
            guard let document = stringAttribute(kAXDocumentAttribute, of: window), let url = documentURL(document), url.isFileURL else { return nil }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue,
                  FileManager.default.isReadableFile(atPath: url.path) else { return nil }
            let minimized = boolAttribute(kAXMinimizedAttribute, of: window) ?? false
            let frame = windowFrame(window)
            let onScreen = !app.isHidden && !minimized && frame.map { candidate in native.contains { approximatelyEqual($0, candidate) && $0.onScreen } } == true
            return PreviewDocumentObservation(path: url.standardizedFileURL.path, displayName: url.lastPathComponent, onScreen: onScreen)
        }
        let unique = observations.reduce(into: [PreviewDocumentObservation]()) { values, item in if !values.contains(where: { $0.path == item.path }) { values.append(item) } }
        if !windows.isEmpty && unique.isEmpty { throw AdapterError.identityUnavailable }
        return unique
    }

    func restore(_ saved: SavedPreviewDocument) async throws -> PreviewDocumentObservation {
        guard saved.applicationBundleID == Self.bundleIdentifier else { throw AdapterError.unavailable("unsupported application identity \(saved.applicationBundleID)") }
        let url = URL(fileURLWithPath: saved.path).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue,
              FileManager.default.isReadableFile(atPath: url.path) else { throw AdapterError.unavailable(saved.path) }
        if let existing = try inventory().first(where: { $0.path == url.path }) { try raise(path: url.path); return existing }
        guard let preview = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleIdentifier) else { throw AdapterError.unavailable("Preview.app") }
        let configuration = NSWorkspace.OpenConfiguration(); configuration.activates = true
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.open([url], withApplicationAt: preview, configuration: configuration) { _, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if let verified = try? inventory().first(where: { $0.path == url.path }) { try raise(path: url.path); return verified }
            try? await Task.sleep(for: .milliseconds(250))
        }
        throw AdapterError.verificationFailed(saved.path)
    }

    func close(_ saved: SavedPreviewDocument) async throws -> Bool {
        guard AXIsProcessTrusted(), let app = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier).first else { return false }
        guard let window = matchingWindow(path: saved.path, pid: app.processIdentifier) else { return false }
        var buttonValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXCloseButtonAttribute as CFString, &buttonValue) == .success,
              let button = buttonValue as! AXUIElement? else { return false }
        guard AXUIElementPerformAction(button, kAXPressAction as CFString) == .success else { return false }
        try? await Task.sleep(for: .milliseconds(750))
        // If an unsaved-change prompt or user cancellation keeps the document
        // present, report that it stayed open rather than bypassing the prompt.
        return matchingWindow(path: saved.path, pid: app.processIdentifier) == nil
    }

    private func raise(path: String) throws {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier).first,
              let window = matchingWindow(path: path, pid: app.processIdentifier),
              app.activate(options: [.activateAllWindows]),
              AXUIElementPerformAction(window, kAXRaiseAction as CFString) == .success else { throw AdapterError.verificationFailed(path) }
    }
    private func matchingWindow(path: String, pid: pid_t) -> AXUIElement? {
        let application = AXUIElementCreateApplication(pid); var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &value) == .success, let windows = value as? [AXUIElement] else { return nil }
        let wanted = URL(fileURLWithPath: path).standardizedFileURL.path
        let matches = windows.filter { stringAttribute(kAXDocumentAttribute, of: $0).flatMap(documentURL)?.standardizedFileURL.path == wanted }
        return matches.count == 1 ? matches[0] : nil
    }
    private func documentURL(_ value: String) -> URL? { value.hasPrefix("file:") ? URL(string: value) : value.hasPrefix("/") ? URL(fileURLWithPath: value) : nil }
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
