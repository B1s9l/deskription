import Foundation

public let desktopFormatVersion = 1

public struct SavedApplication: Codable, Equatable, Sendable, Identifiable {
    public var id: String { bundleIdentifier }
    public let bundleIdentifier: String
    public let displayName: String
    public let savedBundlePath: String?
    public init(bundleIdentifier: String, displayName: String, savedBundlePath: String? = nil) {
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
        self.savedBundlePath = savedBundlePath
    }
}

public enum ApplicationFallback {
    public static func deduplicated(_ applications: [SavedApplication]) -> [SavedApplication] {
        var byBundle: [String: SavedApplication] = [:]
        for application in applications where byBundle[application.bundleIdentifier] == nil { byBundle[application.bundleIdentifier] = application }
        return byBundle.values.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }
    public static func initialSelection(visibility: [String: Bool], selectAll: Bool) -> Set<String> {
        Set(visibility.compactMap { bundleID, visible in selectAll || visible ? bundleID : nil })
    }
}

public struct SavedFinderFolder: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let applicationBundleID: String
    public let sourceWindowID: Int
    public let path: String
    public let frame: Rect
    public init(id: UUID = UUID(), applicationBundleID: String = "com.apple.finder", sourceWindowID: Int, path: String, frame: Rect) {
        self.id = id; self.applicationBundleID = applicationBundleID; self.sourceWindowID = sourceWindowID; self.path = path; self.frame = frame
    }

    private enum CodingKeys: String, CodingKey { case id, applicationBundleID, sourceWindowID, path, frame }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        applicationBundleID = try values.decodeIfPresent(String.self, forKey: .applicationBundleID) ?? "com.apple.finder"
        sourceWindowID = try values.decode(Int.self, forKey: .sourceWindowID)
        path = try values.decode(String.self, forKey: .path)
        frame = try values.decode(Rect.self, forKey: .frame)
    }
}

public struct SavedPreviewDocument: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let applicationBundleID: String
    public let path: String
    public let displayName: String
    public init(id: UUID = UUID(), applicationBundleID: String = "com.apple.Preview", path: String, displayName: String) {
        self.id = id; self.applicationBundleID = applicationBundleID; self.path = path; self.displayName = displayName
    }
    private enum CodingKeys: String, CodingKey { case id, applicationBundleID, path, displayName }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        applicationBundleID = try values.decodeIfPresent(String.self, forKey: .applicationBundleID) ?? "com.apple.Preview"
        path = try values.decode(String.self, forKey: .path)
        displayName = try values.decode(String.self, forKey: .displayName)
    }
}

/// An exact file identity together with the application that originally owned it.
/// Discovery remains application-specific; persistence and explicit application
/// opening use this common representation.
public struct SavedDocumentReference: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let applicationBundleID: String
    public let applicationBundlePath: String?
    public let path: String
    public let displayName: String
    public let identityMetadata: [String: String]

    public init(id: UUID = UUID(), applicationBundleID: String, applicationBundlePath: String? = nil, path: String, displayName: String, identityMetadata: [String: String] = [:]) {
        self.id = id
        self.applicationBundleID = applicationBundleID
        self.applicationBundlePath = applicationBundlePath
        self.path = path
        self.displayName = displayName
        self.identityMetadata = identityMetadata
    }

    public init(_ legacy: SavedPreviewDocument, applicationBundlePath: String? = nil) {
        self.init(id: legacy.id, applicationBundleID: legacy.applicationBundleID, applicationBundlePath: applicationBundlePath, path: legacy.path, displayName: legacy.displayName, identityMetadata: ["legacyType": "preview"])
    }
}

public struct SavedNote: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let noteIdentifier: String
    public let displayName: String
    public init(id: UUID = UUID(), noteIdentifier: String, displayName: String) { self.id = id; self.noteIdentifier = noteIdentifier; self.displayName = displayName }
}

public struct SavedTab: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let sourceTabID: Int?
    public let url: String
    public let title: String
    public let pinned: Bool
    public let active: Bool
    public let order: Int
    public let faviconDataURL: String?
    public init(id: UUID = UUID(), sourceTabID: Int? = nil, url: String, title: String, pinned: Bool, active: Bool, order: Int, faviconDataURL: String? = nil) {
        self.id = id; self.sourceTabID = sourceTabID; self.url = url; self.title = title
        self.pinned = pinned; self.active = active; self.order = order; self.faviconDataURL = faviconDataURL
    }
}

public struct SavedWindow: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let sourceExtensionWindowID: Int?
    public let verifiedNativeWindowID: UInt32?
    public let frame: Rect
    public let state: String
    public let tabs: [SavedTab]
    public init(id: UUID = UUID(), sourceExtensionWindowID: Int? = nil, verifiedNativeWindowID: UInt32? = nil, frame: Rect, state: String, tabs: [SavedTab]) {
        self.id = id; self.sourceExtensionWindowID = sourceExtensionWindowID
        self.verifiedNativeWindowID = verifiedNativeWindowID; self.frame = frame; self.state = state; self.tabs = tabs
    }
}

public struct BrowserProfileState: Codable, Equatable, Sendable, Identifiable {
    public var id: String { installationID }
    public let applicationBundleID: String
    public let installationID: String
    public let adapterStateVersion: Int
    public let launchUserDataDirectory: String?
    public let launchProfileDirectory: String?
    public let browserIdentityVerified: Bool
    public let windows: [SavedWindow]
    public init(applicationBundleID: String, installationID: String, adapterStateVersion: Int, launchUserDataDirectory: String? = nil, launchProfileDirectory: String?, browserIdentityVerified: Bool = true, windows: [SavedWindow]) {
        self.applicationBundleID = applicationBundleID; self.installationID = installationID
        self.adapterStateVersion = adapterStateVersion; self.launchUserDataDirectory = launchUserDataDirectory; self.launchProfileDirectory = launchProfileDirectory; self.browserIdentityVerified = browserIdentityVerified; self.windows = windows
    }
    private enum CodingKeys: String, CodingKey { case applicationBundleID, installationID, adapterStateVersion, launchUserDataDirectory, launchProfileDirectory, browserIdentityVerified, windows }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        applicationBundleID = try values.decode(String.self, forKey: .applicationBundleID); installationID = try values.decode(String.self, forKey: .installationID)
        adapterStateVersion = try values.decode(Int.self, forKey: .adapterStateVersion); launchUserDataDirectory = try values.decodeIfPresent(String.self, forKey: .launchUserDataDirectory); launchProfileDirectory = try values.decodeIfPresent(String.self, forKey: .launchProfileDirectory)
        browserIdentityVerified = try values.decodeIfPresent(Bool.self, forKey: .browserIdentityVerified) ?? false
        windows = try values.decode([SavedWindow].self, forKey: .windows)
    }
}

public struct SavedDesktop: Codable, Equatable, Sendable, Identifiable {
    public let formatVersion: Int
    public let id: UUID
    public var name: String
    public let createdAt: Date
    public var modifiedAt: Date
    public let profiles: [BrowserProfileState]
    public let finderFolders: [SavedFinderFolder]
    public let previewDocuments: [SavedPreviewDocument]
    public let documents: [SavedDocumentReference]
    public let notes: [SavedNote]
    public let applications: [SavedApplication]
    public let limitations: [String]
    public init(formatVersion: Int = desktopFormatVersion, id: UUID = UUID(), name: String, createdAt: Date = Date(), modifiedAt: Date = Date(), profiles: [BrowserProfileState], finderFolders: [SavedFinderFolder] = [], previewDocuments: [SavedPreviewDocument] = [], documents: [SavedDocumentReference] = [], notes: [SavedNote] = [], applications: [SavedApplication] = [], limitations: [String]) {
        self.formatVersion = formatVersion; self.id = id; self.name = name; self.createdAt = createdAt
        self.modifiedAt = modifiedAt; self.profiles = profiles; self.finderFolders = finderFolders; self.previewDocuments = previewDocuments; self.documents = documents; self.notes = notes; self.applications = applications; self.limitations = limitations
    }
    public var tabCount: Int { profiles.flatMap(\.windows).flatMap(\.tabs).count }
    public var documentReferences: [SavedDocumentReference] {
        var result = documents
        for legacy in previewDocuments where !result.contains(where: { $0.applicationBundleID == legacy.applicationBundleID && URL(fileURLWithPath: $0.path).standardizedFileURL.path == URL(fileURLWithPath: legacy.path).standardizedFileURL.path }) {
            result.append(SavedDocumentReference(legacy))
        }
        return result
    }
    public var windowCount: Int { profiles.flatMap(\.windows).count + finderFolders.count + documentReferences.count + notes.count }

    private enum CodingKeys: String, CodingKey { case formatVersion, id, name, createdAt, modifiedAt, profiles, finderFolders, previewDocuments, documents, notes, applications, limitations }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try values.decode(Int.self, forKey: .formatVersion)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        modifiedAt = try values.decode(Date.self, forKey: .modifiedAt)
        profiles = try values.decode([BrowserProfileState].self, forKey: .profiles)
        finderFolders = try values.decodeIfPresent([SavedFinderFolder].self, forKey: .finderFolders) ?? []
        previewDocuments = try values.decodeIfPresent([SavedPreviewDocument].self, forKey: .previewDocuments) ?? []
        documents = try values.decodeIfPresent([SavedDocumentReference].self, forKey: .documents) ?? []
        notes = try values.decodeIfPresent([SavedNote].self, forKey: .notes) ?? []
        applications = try values.decodeIfPresent([SavedApplication].self, forKey: .applications) ?? []
        limitations = try values.decode([String].self, forKey: .limitations)
    }
}

public enum AfterSaveBehavior: String, CaseIterable, Codable, Sendable {
    case keepOpen
    case closeSupportedContent
    case askEveryTime

    public var title: String {
        switch self {
        case .keepOpen: return "Keep open"
        case .closeSupportedContent: return "Close supported content"
        case .askEveryTime: return "Ask every time"
        }
    }
}

public enum AfterSavePromptChoice: Equatable, Sendable { case keepOpen, closeSupportedContent, dismissed }
public enum AfterSaveDecision: Equatable, Sendable { case keepOpen, closeSupportedContent, prompt }

public enum AfterSavePolicy {
    public static func decision(for behavior: AfterSaveBehavior) -> AfterSaveDecision {
        switch behavior {
        case .keepOpen: return .keepOpen
        case .closeSupportedContent: return .closeSupportedContent
        case .askEveryTime: return .prompt
        }
    }
    public static func decision(after choice: AfterSavePromptChoice) -> AfterSaveDecision {
        choice == .closeSupportedContent ? .closeSupportedContent : .keepOpen
    }
    public static func decision(persistenceSucceeded: Bool, behavior: AfterSaveBehavior) -> AfterSaveDecision? {
        guard persistenceSucceeded else { return nil }
        return decision(for: behavior)
    }
}

public struct AfterSavePreferenceStore {
    public static let key = "afterSaveBehavior.v1"
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func behavior(hasExistingDesktops: Bool) -> AfterSaveBehavior {
        if let raw = defaults.string(forKey: Self.key), let saved = AfterSaveBehavior(rawValue: raw) { return saved }
        // Older installations always attempted supported closure. Preserve that
        // established behavior; genuinely new installations get the safer prompt.
        let initial: AfterSaveBehavior = hasExistingDesktops ? .closeSupportedContent : .askEveryTime
        defaults.set(initial.rawValue, forKey: Self.key)
        return initial
    }

    public func set(_ behavior: AfterSaveBehavior) { defaults.set(behavior.rawValue, forKey: Self.key) }
}

public struct DesktopRetentionPreferences: Equatable {
    public static let enabledKey = "desktopRetentionEnabled.v1"
    public static let limitKey = "desktopRetentionLimit.v1"
    public static let defaultLimit = 10
    public static let allowedLimits = 1...50
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public var isEnabled: Bool { defaults.bool(forKey: Self.enabledKey) }
    public var limit: Int {
        guard defaults.object(forKey: Self.limitKey) != nil else { return Self.defaultLimit }
        return min(Self.allowedLimits.upperBound, max(Self.allowedLimits.lowerBound, defaults.integer(forKey: Self.limitKey)))
    }
    public func setEnabled(_ enabled: Bool) { defaults.set(enabled, forKey: Self.enabledKey) }
    public func setLimit(_ limit: Int) { defaults.set(min(Self.allowedLimits.upperBound, max(Self.allowedLimits.lowerBound, limit)), forKey: Self.limitKey) }
}

public struct DesktopNameCounter {
    public static let key = "desktopNameCounter"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func current(existingDesktops: [SavedDesktop]) -> Int {
        if defaults.object(forKey: Self.key) == nil {
            let highestNumber = existingDesktops.compactMap { desktop -> Int? in
                guard desktop.name.hasPrefix("Desktop ") else { return nil }
                return Int(desktop.name.dropFirst("Desktop ".count).prefix { $0.isNumber })
            }.max() ?? 0
            let initial = max(1, max(existingDesktops.count, highestNumber) + 1)
            defaults.set(initial, forKey: Self.key)
            return initial
        }
        return max(1, defaults.integer(forKey: Self.key))
    }

    public func advance(existingDesktops: [SavedDesktop]) {
        defaults.set(current(existingDesktops: existingDesktops) + 1, forKey: Self.key)
    }
}

public struct GenericInventoryPresentation: Equatable, Sendable {
    public let title: String
    public let windowTitles: [String]

    public init(applicationName: String, identifiableWindowTitles: [String]) {
        if identifiableWindowTitles.count == 1 {
            title = "\(applicationName) — \(identifiableWindowTitles[0])"
            windowTitles = []
        } else {
            title = applicationName
            windowTitles = identifiableWindowTitles
        }
    }
}

public enum DesktopRetentionPolicy {
    public static func deletionIDs(desktops: [SavedDesktop], limit: Int, protecting protectedID: UUID? = nil) -> [UUID] {
        let limit = max(1, limit)
        guard desktops.count > limit else { return [] }
        let ordered = desktops.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
        let candidates = ordered.filter { $0.id != protectedID }
        return Array(candidates.prefix(desktops.count - limit)).map(\.id)
    }
}

public struct DesktopDeletionResult: Equatable, Sendable {
    public let requested: Int
    public let deleted: Int
    public let failures: [String]
    public var succeeded: Bool { failures.isEmpty && requested == deleted }
    public init(requested: Int, deleted: Int, failures: [String]) {
        self.requested = requested; self.deleted = deleted; self.failures = failures
    }
}

public struct DesktopContentSummary: Equatable, Sendable {
    public let applicationCount: Int
    public let browserTabCount: Int
    public let folderCount: Int
    public var text: String {
        let application = "\(applicationCount) application\(applicationCount == 1 ? "" : "s")"
        let tabs = "\(browserTabCount) browser tab\(browserTabCount == 1 ? "" : "s")"
        let folders = "\(folderCount) folder\(folderCount == 1 ? "" : "s")"
        return "\(application) · \(tabs) · \(folders)"
    }
}

public struct DesktopContentNode: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case application, profile, window, tab, folder, limitation, empty }
    public let kind: Kind
    public let title: String
    public let subtitle: String?
    public let bundleIdentifier: String?
    public let faviconDataURL: String?
    public let children: [DesktopContentNode]
    public init(kind: Kind, title: String, subtitle: String? = nil, bundleIdentifier: String? = nil, faviconDataURL: String? = nil, children: [DesktopContentNode] = []) {
        self.kind = kind; self.title = title; self.subtitle = subtitle; self.bundleIdentifier = bundleIdentifier; self.faviconDataURL = faviconDataURL; self.children = children
    }
}

public enum DesktopPresentation {
    public static func summary(for desktop: SavedDesktop) -> DesktopContentSummary {
        let integrated = Set(desktop.profiles.map(\.applicationBundleID))
        let documentApplications = Set(desktop.documentReferences.map(\.applicationBundleID))
        let generic = Set(desktop.applications.map(\.bundleIdentifier)).subtracting(integrated).subtracting(documentApplications).subtracting(["com.apple.finder"])
        return DesktopContentSummary(
            applicationCount: integrated.count + generic.count + documentApplications.count + (desktop.finderFolders.isEmpty ? 0 : 1) + (desktop.notes.isEmpty ? 0 : 1),
            browserTabCount: desktop.tabCount,
            folderCount: desktop.finderFolders.count
        )
    }

    public static func hierarchy(for desktop: SavedDesktop, browserName: (String) -> String) -> [DesktopContentNode] {
        let groupedProfiles = Dictionary(grouping: desktop.profiles, by: \.applicationBundleID)
        var nodes: [DesktopContentNode] = groupedProfiles.keys.sorted { browserName($0) < browserName($1) }.map { bundleID in
            let savedWindows = (groupedProfiles[bundleID] ?? []).flatMap { profile in
                profile.windows.map { (profile: profile, window: $0) }
            }
            let windows = savedWindows.enumerated().map { index, saved in
                let profileName = saved.profile.launchProfileDirectory?.trimmingCharacters(in: .whitespacesAndNewlines)
                let profileLabel = profileName?.isEmpty == false ? profileName! : String(saved.profile.installationID.prefix(8))
                let tabCount = saved.window.tabs.count
                return DesktopContentNode(kind: .window, title: "Window \(index + 1)", subtitle: "Profile: \(profileLabel) · \(tabCount) tab\(tabCount == 1 ? "" : "s")", children: saved.window.tabs.sorted { $0.order < $1.order }.map {
                        DesktopContentNode(kind: .tab, title: $0.title.isEmpty ? $0.url : $0.title, subtitle: $0.title.isEmpty ? nil : $0.url, faviconDataURL: $0.faviconDataURL)
                })
            }
            return DesktopContentNode(kind: .application, title: browserName(bundleID), subtitle: "Restorable browser content", bundleIdentifier: bundleID, children: windows)
        }
        if !desktop.finderFolders.isEmpty {
            nodes.append(DesktopContentNode(kind: .application, title: "Finder", subtitle: "Folders can be reopened precisely", bundleIdentifier: "com.apple.finder", children: desktop.finderFolders.map {
                DesktopContentNode(kind: .folder, title: URL(fileURLWithPath: $0.path).lastPathComponent, subtitle: $0.path)
            }))
        }
        for (bundleID, documents) in Dictionary(grouping: desktop.documentReferences, by: \.applicationBundleID).sorted(by: { $0.key < $1.key }) {
            let title: String
            switch bundleID {
            case "com.apple.Preview": title = "Preview"
            case "com.microsoft.Powerpoint": title = "Microsoft PowerPoint"
            default: title = bundleID
            }
            nodes.append(DesktopContentNode(kind: .application, title: title, subtitle: "Documents can be reopened precisely", bundleIdentifier: bundleID, children: documents.map {
                DesktopContentNode(kind: .folder, title: $0.displayName, subtitle: $0.path)
            }))
        }
        if !desktop.notes.isEmpty {
            nodes.append(DesktopContentNode(kind: .application, title: "Notes", subtitle: "Selected notes can be reopened by stable identifier", bundleIdentifier: "com.apple.Notes", children: desktop.notes.map {
                DesktopContentNode(kind: .folder, title: $0.displayName, subtitle: "Saved Notes identifier: \($0.noteIdentifier.suffix(8))")
            }))
        }
        let covered = Set(desktop.profiles.map(\.applicationBundleID)).union(desktop.documentReferences.map(\.applicationBundleID)).union(["com.apple.finder", "com.apple.Notes"])
        nodes += ApplicationFallback.deduplicated(desktop.applications).filter { !covered.contains($0.bundleIdentifier) }.map {
            DesktopContentNode(kind: .application, title: $0.displayName, subtitle: "Application only · internal windows and documents are not captured", bundleIdentifier: $0.bundleIdentifier, children: [DesktopContentNode(kind: .limitation, title: "Opens the application only", subtitle: "Internal content cannot be restored precisely.")])
        }
        if nodes.isEmpty { nodes = [DesktopContentNode(kind: .empty, title: "No recognized content", subtitle: "This Desktop contains no supported applications, browser tabs, or Finder folders.")] }
        return nodes
    }
}

public struct SafeClosePlan: Equatable, Sendable {
    public let browserProfileKeys: [String]
    public let unsupportedFolderCount: Int
    public let unsupportedApplicationCount: Int
    public static func make(for desktop: SavedDesktop) -> SafeClosePlan {
        SafeClosePlan(
            browserProfileKeys: desktop.profiles.map { "\($0.applicationBundleID)|\($0.installationID)" },
            unsupportedFolderCount: desktop.finderFolders.count,
            unsupportedApplicationCount: desktop.applications.count
        )
    }
}

public struct ClosureResultSummary: Equatable, Sendable {
    public let attempted: Int
    public let completed: Int
    public let failedOrCancelled: Int
    public var isPartial: Bool { completed > 0 && failedOrCancelled > 0 }
    public var succeeded: Bool { attempted > 0 && completed == attempted }
    public init(attempted: Int, completed: Int, failedOrCancelled: Int) {
        self.attempted = attempted; self.completed = completed; self.failedOrCancelled = failedOrCancelled
    }
}

public enum DesktopStoreError: LocalizedError, Equatable {
    case incompatibleVersion(Int)
    case corruptFile(String)
    case duplicateIdentifier
    public var errorDescription: String? {
        switch self {
        case .incompatibleVersion(let v): return "Saved Desktop format version \(v) is not supported."
        case .corruptFile(let name): return "Saved Desktop ‘\(name)’ is corrupt and was not overwritten."
        case .duplicateIdentifier: return "A saved Desktop with this identifier already exists."
        }
    }
}

public struct DesktopStore: Sendable {
    public let directory: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    public init(directory: URL) {
        self.directory = directory
        encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
    }
    public static func applicationSupport() throws -> DesktopStore {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return DesktopStore(directory: base.appendingPathComponent("Deskriptions/Desktops", isDirectory: true))
    }
    public func save(_ desktop: SavedDesktop, replacing: Bool = false) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = url(for: desktop.id)
        if FileManager.default.fileExists(atPath: destination.path), !replacing { throw DesktopStoreError.duplicateIdentifier }
        let data = try encoder.encode(desktop)
        let temporary = directory.appendingPathComponent(".\(desktop.id.uuidString).tmp")
        try data.write(to: temporary, options: [.atomic])
        if replacing, FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        try FileManager.default.moveItem(at: temporary, to: destination)
    }
    public func load(_ id: UUID) throws -> SavedDesktop { try decode(url(for: id)) }
    public func list() -> (desktops: [SavedDesktop], errors: [Error]) {
        guard let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return ([], []) }
        var values: [SavedDesktop] = []; var errors: [Error] = []
        for url in urls where url.pathExtension == "json" {
            do { values.append(try decode(url)) } catch { errors.append(error) }
        }
        return (values.sorted { $0.createdAt > $1.createdAt }, errors)
    }
    public func delete(_ id: UUID) throws { try FileManager.default.removeItem(at: url(for: id)) }
    public func deleteAll() throws -> Int {
        let manager = FileManager.default
        guard manager.fileExists(atPath: directory.path) else { return 0 }
        let records = try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
        guard !records.isEmpty else { return 0 }
        let parent = directory.deletingLastPathComponent()
        let backup = parent.appendingPathComponent(".Desktops-delete-\(UUID().uuidString)", isDirectory: true)
        try manager.moveItem(at: directory, to: backup)
        do { try manager.createDirectory(at: directory, withIntermediateDirectories: true) }
        catch {
            try? manager.moveItem(at: backup, to: directory)
            throw error
        }
        do { try manager.removeItem(at: backup) }
        catch {
            // Deletion is logically complete, but keep the isolated backup rather
            // than risk corrupting the new store. Surface the cleanup failure.
            throw error
        }
        return records.count
    }
    public func applyRetention(limit: Int, protecting protectedID: UUID? = nil) -> DesktopDeletionResult {
        let listing = list()
        let ids = DesktopRetentionPolicy.deletionIDs(desktops: listing.desktops, limit: limit, protecting: protectedID)
        var deleted = 0, failures: [String] = listing.errors.map(\.localizedDescription)
        for id in ids {
            do { try delete(id); deleted += 1 }
            catch { failures.append("\(id.uuidString): \(error.localizedDescription)") }
        }
        return DesktopDeletionResult(requested: ids.count, deleted: deleted, failures: failures)
    }
    public func url(for id: UUID) -> URL { directory.appendingPathComponent(id.uuidString).appendingPathExtension("json") }
    private func decode(_ url: URL) throws -> SavedDesktop {
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw DesktopStoreError.corruptFile(url.lastPathComponent) }
        guard let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let version = envelope["formatVersion"] as? Int else {
            throw DesktopStoreError.corruptFile(url.lastPathComponent)
        }
        guard version == desktopFormatVersion else { throw DesktopStoreError.incompatibleVersion(version) }
        do { return try decoder.decode(SavedDesktop.self, from: data) }
        catch { throw DesktopStoreError.corruptFile(url.lastPathComponent) }
    }
}

public enum SelectionState: Equatable, Sendable { case off, on, mixed }
public struct ContentIdentity: Hashable, Sendable {
    public let profileID: String
    public let tabID: Int
    public init(profileID: String, tabID: Int) { self.profileID = profileID; self.tabID = tabID }
}
public struct DesktopSelection: Equatable, Sendable {
    public var content: Set<ContentIdentity>
    public init(content: Set<ContentIdentity> = []) { self.content = content }
    public mutating func set(window: BrowserWindow, profileID: String, selected: Bool) {
        for tab in window.tabs { let key = ContentIdentity(profileID: profileID, tabID: tab.id); if selected { content.insert(key) } else { content.remove(key) } }
    }
    public mutating func set(tabID: Int, profileID: String, selected: Bool) { let key = ContentIdentity(profileID: profileID, tabID: tabID); if selected { content.insert(key) } else { content.remove(key) } }
    public func contains(tabID: Int, profileID: String) -> Bool { content.contains(.init(profileID: profileID, tabID: tabID)) }
    public func state(for window: BrowserWindow, profileID: String) -> SelectionState {
        let selected = window.tabs.filter { contains(tabID: $0.id, profileID: profileID) }.count
        return selected == 0 ? .off : selected == window.tabs.count ? .on : .mixed
    }
}

public struct LoadAttempt: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable { case prepared, running, partial, complete, failed, cancelled, indeterminate }
    public let attemptID: UUID
    public let desktopID: UUID
    public let operationID: UUID
    public var status: Status
    public var restoredWindowIDs: [Int]
    public var error: String?
    public init(attemptID: UUID = UUID(), desktopID: UUID, operationID: UUID = UUID(), status: Status = .prepared, restoredWindowIDs: [Int] = [], error: String? = nil) {
        self.attemptID = attemptID; self.desktopID = desktopID; self.operationID = operationID
        self.status = status; self.restoredWindowIDs = restoredWindowIDs; self.error = error
    }
    public static func finalStatus(successfulProfiles: Int, totalProfiles: Int, current: Status, cancelled: Bool) -> Status {
        if cancelled { return .cancelled }
        if successfulProfiles == totalProfiles { return .complete }
        if successfulProfiles > 0, current != .indeterminate { return .partial }
        return current == .running ? .failed : current
    }
}

public struct LoadAttemptStore: Sendable {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }
    public static func applicationSupport() throws -> LoadAttemptStore {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return LoadAttemptStore(directory: base.appendingPathComponent("Deskriptions/Operations", isDirectory: true))
    }
    public func save(_ attempt: LoadAttempt) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(attempt).write(to: url(attempt.attemptID), options: .atomic)
    }
    public func incomplete(for desktopID: UUID) -> [LoadAttempt] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return [] }
        return files.compactMap { try? JSONDecoder().decode(LoadAttempt.self, from: Data(contentsOf: $0)) }
            .filter { $0.desktopID == desktopID && ![.complete, .cancelled].contains($0.status) }
    }
    public func all() -> [LoadAttempt] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return [] }
        return files.compactMap { try? JSONDecoder().decode(LoadAttempt.self, from: Data(contentsOf: $0)) }
    }
    public func url(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString).appendingPathExtension("json") }
}

