import Foundation

public struct DiagnosticReport: Codable, Equatable, Sendable {
    public let generatedAt: Date
    public let appVersion: String
    public let operatingSystem: String
    public let protocolVersion: Int
    public let desktopFormatVersion: Int
    public let savedDesktopCount: Int
    public let unreadableDesktopCount: Int
    public let savedWindowCount: Int
    public let savedTabCount: Int
    public let connectedProfileCount: Int
    public let connectedWindowCount: Int
    public let connectedTabCount: Int
    public let operationStatusCounts: [String: Int]
    public let privacyNotice: String

    public init(generatedAt: Date = Date(), appVersion: String, operatingSystem: String,
                protocolVersion: Int, desktopFormatVersion: Int, savedDesktopCount: Int,
                unreadableDesktopCount: Int, savedWindowCount: Int, savedTabCount: Int,
                connectedProfileCount: Int, connectedWindowCount: Int, connectedTabCount: Int,
                operationStatusCounts: [String: Int]) {
        self.generatedAt = generatedAt; self.appVersion = appVersion; self.operatingSystem = operatingSystem
        self.protocolVersion = protocolVersion; self.desktopFormatVersion = desktopFormatVersion
        self.savedDesktopCount = savedDesktopCount; self.unreadableDesktopCount = unreadableDesktopCount
        self.savedWindowCount = savedWindowCount; self.savedTabCount = savedTabCount
        self.connectedProfileCount = connectedProfileCount; self.connectedWindowCount = connectedWindowCount
        self.connectedTabCount = connectedTabCount; self.operationStatusCounts = operationStatusCounts
        self.privacyNotice = "Counts and version information only. URLs, page titles, Desktop names, profile identities, credentials, and saved Desktop contents are excluded."
    }
}

public enum DiagnosticExporter {
    public static func makeReport(appVersion: String, desktopStore: DesktopStore,
                                  attemptStore: LoadAttemptStore, connectedProfiles: [ExtensionHello],
                                  operatingSystem: String = ProcessInfo.processInfo.operatingSystemVersionString) -> DiagnosticReport {
        let listing = desktopStore.list()
        let attempts = attemptStore.all()
        let statuses = Dictionary(grouping: attempts, by: { $0.status.rawValue }).mapValues(\.count)
        return DiagnosticReport(appVersion: appVersion, operatingSystem: operatingSystem,
            protocolVersion: protocolVersion, desktopFormatVersion: desktopFormatVersion,
            savedDesktopCount: listing.desktops.count, unreadableDesktopCount: listing.errors.count,
            savedWindowCount: listing.desktops.reduce(0) { $0 + $1.windowCount },
            savedTabCount: listing.desktops.reduce(0) { $0 + $1.tabCount },
            connectedProfileCount: connectedProfiles.count,
            connectedWindowCount: connectedProfiles.reduce(0) { $0 + $1.windows.count },
            connectedTabCount: connectedProfiles.reduce(0) { $0 + $1.windows.reduce(0) { $0 + $1.tabs.count } },
            operationStatusCounts: statuses)
    }

    public static func encode(_ report: DiagnosticReport) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(report)
    }
}
