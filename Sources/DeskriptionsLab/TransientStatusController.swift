import AppKit

@MainActor
final class TransientStatusController {
    struct Entry { let date: Date; let title: String; let detail: String }
    private var panel: NSPanel?
    private var titleLabel: NSTextField?
    private var detailLabel: NSTextField?
    private var dismissWork: DispatchWorkItem?
    private(set) var entries: [Entry] = []

    func record(title: String, detail: String) {
        entries.insert(.init(date: Date(), title: title, detail: detail), at: 0)
        if entries.count > 30 { entries.removeLast(entries.count - 30) }
    }

    func show(title: String, detail: String, duration: TimeInterval = 4) {
        record(title: title, detail: detail)
        let panel = panel ?? makePanel()
        titleLabel?.stringValue = title
        detailLabel?.stringValue = detail
        position(panel)
        panel.orderFrontRegardless()
        dismissWork?.cancel()
        let work = DispatchWorkItem { [weak panel] in panel?.orderOut(nil) }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    func update(title: String, detail: String) {
        titleLabel?.stringValue = title; detailLabel?.stringValue = detail
        if let panel { position(panel); panel.orderFrontRegardless() }
    }

    func hide() { dismissWork?.cancel(); panel?.orderOut(nil) }

    func showHistory() {
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 620, height: 380), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Recent Deskriptions Status"
        let scroll = NSScrollView(frame: NSRect(x: 16, y: 16, width: 588, height: 348)); scroll.hasVerticalScroller = true
        let text = NSTextView(frame: scroll.bounds); text.isEditable = false; text.isSelectable = true
        let formatter = DateFormatter(); formatter.dateStyle = .none; formatter.timeStyle = .medium
        text.string = entries.isEmpty ? "No recent operations." : entries.map { "\(formatter.string(from: $0.date))  \($0.title)\n\($0.detail)" }.joined(separator: "\n\n")
        scroll.documentView = text; window.contentView?.addSubview(scroll); window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 94), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating; panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true; panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let visual = NSVisualEffectView(frame: panel.contentView!.bounds); visual.material = .hudWindow; visual.state = .active; visual.wantsLayer = true; visual.layer?.cornerRadius = 12; visual.autoresizingMask = [.width, .height]
        let title = NSTextField(labelWithString: ""); title.font = .boldSystemFont(ofSize: 14); title.frame = NSRect(x: 18, y: 54, width: 404, height: 22)
        let detail = NSTextField(wrappingLabelWithString: ""); detail.frame = NSRect(x: 18, y: 14, width: 404, height: 38); detail.maximumNumberOfLines = 2
        visual.addSubview(title); visual.addSubview(detail); panel.contentView?.addSubview(visual)
        self.panel = panel; titleLabel = title; detailLabel = detail; return panel
    }

    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: visible.maxX - panel.frame.width - 20, y: visible.maxY - panel.frame.height - 20))
    }
}
