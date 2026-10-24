import AppKit
import DeskriptionsCore

private final class DesktopOutlineItem: NSObject {
    let node: DesktopContentNode
    let children: [DesktopOutlineItem]
    init(_ node: DesktopContentNode) { self.node = node; children = node.children.map(DesktopOutlineItem.init) }
}

@MainActor
final class DesktopsBrowserController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSOutlineViewDataSource, NSOutlineViewDelegate, NSWindowDelegate {
    private var desktops: [SavedDesktop]
    private let icon: (String) -> NSImage
    private let onLoad: (SavedDesktop) -> Void
    private let onDelete: (SavedDesktop) -> Void
    private var panel: NSPanel!
    private var table: NSTableView!
    private var outline: NSOutlineView!
    private var detailName: NSTextField!
    private var detailDate: NSTextField!
    private var detailSummary: NSTextField!
    private var outlineRoots: [DesktopOutlineItem] = []
    private var faviconCache: [String: NSImage] = [:]
    private var faviconLoads = Set<String>()
    private var didBuild = false

    init(desktops: [SavedDesktop], icon: @escaping (String) -> NSImage, onLoad: @escaping (SavedDesktop) -> Void, onDelete: @escaping (SavedDesktop) -> Void) {
        self.desktops = desktops; self.icon = icon; self.onLoad = onLoad; self.onDelete = onDelete
        super.init(); build()
    }

    func show() {
        panel.center(); panel.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false); panel.makeFirstResponder(table); updateDetail()
    }
    func close() { panel.orderOut(nil) }
    func numberOfRows(in tableView: NSTableView) -> Int { desktops.count }
    func tableViewSelectionDidChange(_ notification: Notification) { if didBuild { updateDetail() } }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let desktop = desktops[row], cell = NSTableCellView(frame: NSRect(x: 0, y: 0, width: 294, height: 64))
        let name = NSTextField(labelWithString: desktop.name)
        name.font = .systemFont(ofSize: 14, weight: .semibold); name.lineBreakMode = .byTruncatingTail; name.frame = NSRect(x: 12, y: 36, width: 270, height: 20); name.toolTip = desktop.name
        let metadata = NSTextField(labelWithString: desktop.createdAt.formatted(date: .abbreviated, time: .shortened))
        metadata.textColor = .secondaryLabelColor; metadata.font = .systemFont(ofSize: 11); metadata.frame = NSRect(x: 12, y: 20, width: 270, height: 16)
        let summary = NSTextField(labelWithString: DesktopPresentation.summary(for: desktop).text)
        summary.textColor = .tertiaryLabelColor; summary.font = .systemFont(ofSize: 10); summary.lineBreakMode = .byTruncatingTail; summary.frame = NSRect(x: 12, y: 4, width: 270, height: 15)
        cell.addSubview(name); cell.addSubview(metadata); cell.addSubview(summary)
        cell.setAccessibilityLabel("\(desktop.name), \(metadata.stringValue), \(summary.stringValue)")
        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { (item as? DesktopOutlineItem)?.children.count ?? outlineRoots.count }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { (item as? DesktopOutlineItem)?.children[index] ?? outlineRoots[index] }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { !((item as? DesktopOutlineItem)?.children.isEmpty ?? true) }
    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat { (item as? DesktopOutlineItem)?.node.kind == .application ? 52 : 40 }
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let item = item as? DesktopOutlineItem else { return nil }
        let node = item.node, height: CGFloat = node.kind == .application ? 52 : 40
        let cell = NSTableCellView(frame: NSRect(x: 0, y: 0, width: 500, height: height))
        let imageSize: CGFloat = node.kind == .application ? 30 : 26
        let image = NSImageView(frame: NSRect(x: 4, y: (height - imageSize) / 2, width: imageSize, height: imageSize)); image.imageScaling = .scaleProportionallyDown; image.image = imageFor(node)
        let title = NSTextField(labelWithString: node.title)
        title.font = .systemFont(ofSize: node.kind == .application ? 13 : 12, weight: node.kind == .application ? .semibold : .regular)
        title.lineBreakMode = .byTruncatingMiddle
        if node.kind == .window { title.frame = NSRect(x: 38, y: (height - 19) / 2, width: 78, height: 19) }
        else { title.frame = NSRect(x: 38, y: node.subtitle == nil ? (height - 20) / 2 : height - 23, width: 440, height: 19) }
        title.toolTip = node.title
        cell.addSubview(image); cell.addSubview(title)
        if let subtitle = node.subtitle {
            let secondary = NSTextField(labelWithString: subtitle); secondary.font = .systemFont(ofSize: 10.5); secondary.textColor = .secondaryLabelColor
            secondary.lineBreakMode = .byTruncatingMiddle
            secondary.frame = node.kind == .window ? NSRect(x: 120, y: (height - 16) / 2, width: 358, height: 16) : NSRect(x: 38, y: 4, width: 440, height: 16)
            secondary.toolTip = subtitle; cell.addSubview(secondary)
        }
        cell.setAccessibilityLabel(node.subtitle.map { "\(node.title), \($0)" } ?? node.title)
        return cell
    }

    private func imageFor(_ node: DesktopContentNode) -> NSImage? {
        if node.kind == .application, let bundleID = node.bundleIdentifier {
            let applicationIcon = (icon(bundleID).copy() as? NSImage) ?? icon(bundleID)
            applicationIcon.size = NSSize(width: 30, height: 30)
            return applicationIcon
        }
        if node.kind == .tab, let dataURL = node.faviconDataURL {
            if let image = faviconCache[dataURL] { return image }
            loadFavicon(dataURL)
        }
        let symbol: String
        switch node.kind {
        case .profile: symbol = "person.crop.circle"
        case .window: symbol = "macwindow"
        case .tab: symbol = "globe"
        case .folder: symbol = "folder"
        case .limitation: symbol = "info.circle"
        case .empty: symbol = "tray"
        case .application: symbol = "app"
        }
        return NSImage(systemSymbolName: symbol, accessibilityDescription: node.title)
    }

    private func loadFavicon(_ dataURL: String) {
        guard !faviconLoads.contains(dataURL) else { return }
        faviconLoads.insert(dataURL)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let encoded = dataURL.split(separator: ",", maxSplits: 1).last.map(String.init)
            let image = encoded.flatMap { Data(base64Encoded: $0) }.flatMap(NSImage.init(data:))
            DispatchQueue.main.async {
                guard let self else { return }
                self.faviconLoads.remove(dataURL)
                guard let image else { return }
                image.size = NSSize(width: 20, height: 20); self.faviconCache[dataURL] = image
                self.outline.reloadData(); self.outlineRoots.forEach(self.expandRecursively)
            }
        }
    }

    private func build() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 940, height: 600), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.title = "Desktops"; panel.delegate = self; panel.minSize = NSSize(width: 720, height: 440)
        let container = NSView(frame: NSRect(x: 16, y: 62, width: 908, height: 522)); container.autoresizingMask = [.width, .height]
        table = NSTableView(); table.headerView = nil; table.rowHeight = 64; table.intercellSpacing = NSSize(width: 0, height: 2); table.delegate = self; table.dataSource = self; table.allowsEmptySelection = false
        table.addTableColumn(NSTableColumn(identifier: .init("desktop"))); table.doubleAction = #selector(loadSelected); table.target = self; table.setAccessibilityLabel("Saved Desktops")
        let listScroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 522)); listScroll.documentView = table; listScroll.hasVerticalScroller = true; listScroll.borderType = .bezelBorder; listScroll.autoresizingMask = [.height]
        let detail = NSView(frame: NSRect(x: 301, y: 0, width: 607, height: 522)); detail.autoresizingMask = [.width, .height]
        detailName = NSTextField(wrappingLabelWithString: ""); detailName.font = .systemFont(ofSize: 20, weight: .semibold); detailName.maximumNumberOfLines = 2; detailName.frame = NSRect(x: 18, y: 466, width: 560, height: 48); detailName.autoresizingMask = [.width, .minYMargin]
        detailDate = NSTextField(labelWithString: ""); detailDate.textColor = .secondaryLabelColor; detailDate.frame = NSRect(x: 18, y: 442, width: 560, height: 18); detailDate.autoresizingMask = [.width, .minYMargin]
        detailSummary = NSTextField(labelWithString: ""); detailSummary.font = .systemFont(ofSize: 12, weight: .medium); detailSummary.frame = NSRect(x: 18, y: 416, width: 560, height: 18); detailSummary.autoresizingMask = [.width, .minYMargin]
        let separator = NSBox(frame: NSRect(x: 18, y: 404, width: 560, height: 1)); separator.boxType = .separator; separator.autoresizingMask = [.width, .minYMargin]
        outline = NSOutlineView(); outline.headerView = nil; outline.delegate = self; outline.dataSource = self; outline.indentationPerLevel = 18; outline.selectionHighlightStyle = .none
        let column = NSTableColumn(identifier: .init("contents")); column.resizingMask = .autoresizingMask; outline.addTableColumn(column); outline.outlineTableColumn = column; outline.setAccessibilityLabel("Selected Desktop contents")
        let detailScroll = NSScrollView(frame: NSRect(x: 12, y: 8, width: 576, height: 386)); detailScroll.documentView = outline; detailScroll.hasVerticalScroller = true; detailScroll.borderType = .noBorder; detailScroll.autoresizingMask = [.width, .height]
        [detailName, detailDate, detailSummary, separator, detailScroll].forEach(detail.addSubview)
        let divider = NSBox(frame: NSRect(x: 300, y: 0, width: 1, height: 522)); divider.boxType = .separator; divider.autoresizingMask = [.height]
        container.addSubview(listScroll); container.addSubview(divider); container.addSubview(detail); panel.contentView?.addSubview(container)
        let load = NSButton(title: "Load selected", target: self, action: #selector(loadSelected)); load.keyEquivalent = "\r"; load.frame = NSRect(x: 794, y: 16, width: 130, height: 32); load.autoresizingMask = [.minXMargin, .maxYMargin]
        let delete = NSButton(title: "Delete selected", target: self, action: #selector(deleteSelected)); delete.frame = NSRect(x: 652, y: 16, width: 132, height: 32); delete.autoresizingMask = [.minXMargin, .maxYMargin]
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel)); cancel.keyEquivalent = "\u{1b}"; cancel.frame = NSRect(x: 552, y: 16, width: 90, height: 32); cancel.autoresizingMask = [.minXMargin, .maxYMargin]
        panel.contentView?.addSubview(load); panel.contentView?.addSubview(delete); panel.contentView?.addSubview(cancel); didBuild = true
    }

    private func updateDetail() {
        guard desktops.indices.contains(table.selectedRow) else { return }
        let desktop = desktops[table.selectedRow]
        detailName.stringValue = desktop.name; detailName.toolTip = desktop.name
        detailDate.stringValue = "Saved \(desktop.createdAt.formatted(date: .long, time: .shortened))"
        detailSummary.stringValue = DesktopPresentation.summary(for: desktop).text
        outlineRoots = DesktopPresentation.hierarchy(for: desktop, browserName: ChromiumBrowser.displayName(for:)).map(DesktopOutlineItem.init)
        outline.reloadData()
        for root in outlineRoots { expandRecursively(root) }
    }

    private func expandRecursively(_ item: DesktopOutlineItem) {
        guard !item.children.isEmpty else { return }
        outline.expandItem(item)
        item.children.forEach(expandRecursively)
    }

    @objc private func loadSelected() { guard desktops.indices.contains(table.selectedRow) else { return }; let selected = desktops[table.selectedRow]; close(); onLoad(selected) }
    @objc private func deleteSelected() { guard desktops.indices.contains(table.selectedRow) else { return }; onDelete(desktops[table.selectedRow]) }
    @objc private func cancel() { close() }
}
