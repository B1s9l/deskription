import AppKit
import ApplicationServices
import DeskriptionsCore

struct GenericWindowObservation: Equatable {
    let windowID: UInt32
    let title: String?
    let onScreen: Bool
}

struct GenericApplicationObservation: Equatable {
    let bundleIdentifier: String
    let displayName: String
    let bundlePath: String?
    let processIdentifier: pid_t
    let hasOnScreenWindow: Bool
    let windows: [GenericWindowObservation]
}

final class GenericApplicationAdapter {
    func inventory(nativeWindows: [NativeWindow], ownBundleID: String?, integratedBrowserBundleIDs: Set<String> = []) -> [GenericApplicationObservation] {
        let dedicatedBundleIDs = integratedBrowserBundleIDs.union(["com.apple.finder"])
        let grouped = Dictionary(grouping: nativeWindows, by: \.ownerPID)
        let observations: [GenericApplicationObservation] = grouped.compactMap { (pid, windows) -> GenericApplicationObservation? in
            guard let app = NSRunningApplication(processIdentifier: pid),
                  app.activationPolicy == .regular,
                  let bundleID = app.bundleIdentifier,
                  bundleID != ownBundleID,
                  !dedicatedBundleIDs.contains(bundleID),
                  !bundleID.hasPrefix("com.apple.WebKit."),
                  !bundleID.hasSuffix(".helper") else { return nil }
            let name = app.localizedName ?? windows.first?.ownerName ?? bundleID
            let visibleWindows = windows.sorted { ($0.onScreen ? 0 : 1, $0.windowID) < ($1.onScreen ? 0 : 1, $1.windowID) }
            let axTitles = accessibilityWindowTitles(pid: pid, nativeWindows: visibleWindows)
            let observed = visibleWindows.map { window in
                GenericWindowObservation(windowID: window.windowID,
                                         title: meaningful(window.title) ?? axTitles[window.windowID],
                                         onScreen: window.onScreen)
            }
            return GenericApplicationObservation(bundleIdentifier: bundleID,
                                                 displayName: name,
                                                 bundlePath: app.bundleURL?.path,
                                                 processIdentifier: pid,
                                                 hasOnScreenWindow: windows.contains(where: \.onScreen),
                                                 windows: observed)
        }
        return Dictionary(grouping: observations, by: { $0.bundleIdentifier }).values.compactMap { entries in
            guard let first = entries.first else { return nil }
            let windows = entries.flatMap(\.windows).reduce(into: [GenericWindowObservation]()) { result, item in
                if !result.contains(where: { $0.windowID == item.windowID }) { result.append(item) }
            }.sorted { ($0.onScreen ? 0 : 1, $0.windowID) < ($1.onScreen ? 0 : 1, $1.windowID) }
            return GenericApplicationObservation(bundleIdentifier: first.bundleIdentifier, displayName: first.displayName, bundlePath: entries.compactMap(\.bundlePath).first, processIdentifier: first.processIdentifier, hasOnScreenWindow: entries.contains(where: \.hasOnScreenWindow), windows: windows)
        }.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    private func meaningful(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// CGWindow supplies stable window IDs and visibility. Accessibility is used
    /// only as a title fallback when Window Server redacts a title. AX and CG
    /// windows are correlated by their public position and size attributes.
    private func accessibilityWindowTitles(pid: pid_t, nativeWindows: [NativeWindow]) -> [UInt32: String] {
        guard AXIsProcessTrusted() else { return [:] }
        let application = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return [:] }
        return windows.reduce(into: [:]) { result, element in
            guard let frame = accessibilityFrame(element),
                  let id = nativeWindows.first(where: { window in
                      approximatelyEqual(CGRect(x: window.bounds.x, y: window.bounds.y, width: window.bounds.width, height: window.bounds.height), frame)
                  })?.windowID else { return }
            var titleValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleValue) == .success,
                  let title = titleValue as? String, let title = meaningful(title) else { return }
            result[id] = title
        }
    }

    private func accessibilityFrame(_ element: AXUIElement) -> CGRect? {
        var position: CFTypeRef?, size: CFTypeRef?, point = CGPoint.zero, dimensions = CGSize.zero
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size, CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID(),
              AXValueGetValue(position as! AXValue, .cgPoint, &point), AXValueGetValue(size as! AXValue, .cgSize, &dimensions) else { return nil }
        return CGRect(origin: point, size: dimensions)
    }

    private func approximatelyEqual(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) < 5 && abs(lhs.minY - rhs.minY) < 5 && abs(lhs.width - rhs.width) < 5 && abs(lhs.height - rhs.height) < 5
    }

    func restore(_ saved: SavedApplication) async -> Result<String, Error> {
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: saved.bundleIdentifier).first {
            guard !running.isTerminated, running.activate(options: [.activateAllWindows]) else {
                return .failure(AdapterError.activationFailed(saved.displayName))
            }
            return await waitUntilActive(running, name: saved.displayName, result: "already running, reused, and brought to the front — window contents were not restored.")
        }
        let savedLocation = saved.savedBundlePath.map(URL.init(fileURLWithPath:)).flatMap { url -> URL? in
            guard FileManager.default.fileExists(atPath: url.path),
                  Bundle(url: url)?.bundleIdentifier == saved.bundleIdentifier else { return nil }
            return url
        }
        let located = savedLocation ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: saved.bundleIdentifier)
        guard let located else { return .failure(AdapterError.unavailable(saved.displayName)) }
        guard Bundle(url: located)?.bundleIdentifier == saved.bundleIdentifier else {
            return .failure(AdapterError.identityMismatch(saved.displayName))
        }
        do {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            let launched = try await NSWorkspace.shared.openApplication(at: located, configuration: configuration)
            let deadline = Date().addingTimeInterval(15)
            while Date() < deadline {
                if !launched.isTerminated,
                   launched.bundleIdentifier == saved.bundleIdentifier,
                   NSRunningApplication.runningApplications(withBundleIdentifier: saved.bundleIdentifier).contains(where: { !$0.isTerminated }) {
                    if !launched.isActive { _ = launched.activate(options: [.activateAllWindows]) }
                    if launched.isActive { return .success("\(saved.displayName): launched, verified, and brought to the front — window contents were not restored.") }
                }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            return .failure(AdapterError.verificationFailed(saved.displayName))
        } catch { return .failure(error) }
    }

    enum AdapterError: LocalizedError {
        case unavailable(String), identityMismatch(String), activationFailed(String), verificationFailed(String)
        var errorDescription: String? {
            switch self {
            case .unavailable(let name): return "\(name) is not installed at its saved location and could not be found by bundle identity."
            case .identityMismatch(let name): return "The located application for \(name) does not match its saved bundle identity, so it was not opened."
            case .activationFailed(let name): return "\(name) is running, but Deskriptions could not bring it to the front."
            case .verificationFailed(let name): return "\(name) was asked to open, but Deskriptions could not verify that it was running."
            }
        }
    }

    private func waitUntilActive(_ application: NSRunningApplication, name: String, result: String) async -> Result<String, Error> {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if application.isTerminated { return .failure(AdapterError.verificationFailed(name)) }
            if application.isActive { return .success("\(name): \(result)") }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return .failure(AdapterError.activationFailed(name))
    }
}
