import AppKit
import DeskriptionsCore

struct GenericApplicationObservation: Equatable {
    let bundleIdentifier: String
    let displayName: String
    let bundlePath: String?
    let processIdentifier: pid_t
    let hasOnScreenWindow: Bool
}

@MainActor
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
            return GenericApplicationObservation(bundleIdentifier: bundleID,
                                                 displayName: name,
                                                 bundlePath: app.bundleURL?.path,
                                                 processIdentifier: pid,
                                                 hasOnScreenWindow: windows.contains(where: \.onScreen))
        }
        return Dictionary(grouping: observations, by: { $0.bundleIdentifier }).values.compactMap { entries in
            guard let first = entries.first else { return nil }
            return GenericApplicationObservation(bundleIdentifier: first.bundleIdentifier, displayName: first.displayName, bundlePath: entries.compactMap(\.bundlePath).first, processIdentifier: first.processIdentifier, hasOnScreenWindow: entries.contains(where: \.hasOnScreenWindow))
        }.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
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
