import AppKit
import DeskriptionsCore

struct DocumentObservation: Equatable {
    let applicationBundleID: String
    let applicationBundlePath: String?
    let path: String
    let displayName: String
    let onScreen: Bool
    let identityMetadata: [String: String]

    var identityKey: String { "\(applicationBundleID)|\(URL(fileURLWithPath: path).standardizedFileURL.path)" }
    var savedReference: SavedDocumentReference {
        SavedDocumentReference(applicationBundleID: applicationBundleID, applicationBundlePath: applicationBundlePath, path: path, displayName: displayName, identityMetadata: identityMetadata)
    }
}

protocol DocumentDiscoveryAdapter: AnyObject {
    var applicationBundleID: String { get }
    var applicationDisplayName: String { get }
    func inventoryWithRetry() async throws -> [DocumentObservation]
    func observation(forPath path: String) async throws -> DocumentObservation?
    func finalVerification(forPath path: String) async throws -> DocumentObservation?
    func bringToFront(path: String) throws
    func close(path: String) async throws -> Bool
}

extension DocumentDiscoveryAdapter {
    func close(path: String) async throws -> Bool { false }
    func observation(forPath path: String) async throws -> DocumentObservation? {
        let wanted = URL(fileURLWithPath: path).standardizedFileURL.path
        return try await inventoryWithRetry().first { URL(fileURLWithPath: $0.path).standardizedFileURL.path == wanted }
    }
    func finalVerification(forPath path: String) async throws -> DocumentObservation? { try await observation(forPath: path) }
}

struct DocumentRestorationResult {
    enum Verification: Equatable { case verifiedExact, commandAcceptedVerificationUnavailable }
    let observation: DocumentObservation?
    let verification: Verification
}

@MainActor
final class DocumentRestorer {
    enum RestorationError: LocalizedError {
        case unavailable(String)
        case applicationUnavailable(String)
        case applicationIdentityMismatch(String)
        case verificationFailed(String)

        var errorDescription: String? {
            switch self {
            case .unavailable(let path): return "The saved document is missing, inaccessible, or unreadable: \(path)"
            case .applicationUnavailable(let bundleID): return "The recorded application is not installed or cannot be found: \(bundleID)"
            case .applicationIdentityMismatch(let path): return "The application at the saved location no longer has the recorded identity: \(path)"
            case .verificationFailed(let path): return "The recorded application launched, but Deskriptions could not verify that it opened: \(path)"
            }
        }
    }

    func restore(_ saved: SavedDocumentReference, using adapter: any DocumentDiscoveryAdapter, timeout: Duration = .seconds(10)) async throws -> DocumentRestorationResult {
        guard saved.applicationBundleID == adapter.applicationBundleID else {
            throw RestorationError.applicationIdentityMismatch(saved.applicationBundleID)
        }
        let fileURL = URL(fileURLWithPath: saved.path).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory),
              !isDirectory.boolValue, FileManager.default.isReadableFile(atPath: fileURL.path) else {
            throw RestorationError.unavailable(saved.path)
        }

        if let existing = try await adapter.observation(forPath: fileURL.path) {
            try adapter.bringToFront(path: fileURL.path)
            return .init(observation: existing, verification: .verifiedExact)
        }

        let applicationURL = try locateApplication(for: saved)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.open([fileURL], withApplicationAt: applicationURL, configuration: configuration) { _, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        repeat {
            if let verified = try? await adapter.observation(forPath: fileURL.path) {
                try adapter.bringToFront(path: fileURL.path)
                return .init(observation: verified, verification: .verifiedExact)
            }
            try? await Task.sleep(for: .milliseconds(250))
        } while clock.now < deadline
        // Some applications accept and complete the explicit open request before
        // publishing AXDocument. Give the adapter one bounded, application-specific
        // confirmation opportunity; this must not rebuild a full inventory in each
        // polling iteration.
        if let verified = try? await adapter.finalVerification(forPath: fileURL.path) {
            try adapter.bringToFront(path: fileURL.path)
            return .init(observation: verified, verification: .verifiedExact)
        }
        return .init(observation: nil, verification: .commandAcceptedVerificationUnavailable)
    }

    private func locateApplication(for saved: SavedDocumentReference) throws -> URL {
        if let path = saved.applicationBundlePath {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: url.path) {
                guard Bundle(url: url)?.bundleIdentifier == saved.applicationBundleID else {
                    throw RestorationError.applicationIdentityMismatch(path)
                }
                return url
            }
        }
        guard let located = NSWorkspace.shared.urlForApplication(withBundleIdentifier: saved.applicationBundleID) else {
            throw RestorationError.applicationUnavailable(saved.applicationBundleID)
        }
        guard Bundle(url: located)?.bundleIdentifier == saved.applicationBundleID else {
            throw RestorationError.applicationIdentityMismatch(located.path)
        }
        return located
    }

    private func standardized(_ path: String) -> String { URL(fileURLWithPath: path).standardizedFileURL.path }
}
