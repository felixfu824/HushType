import AppKit
import SwiftUI

/// Small app tile that can be dragged into macOS permission lists.
///
/// This is intentionally a fallback affordance for System Settings. The
/// primary path remains toggling HushType on in the permission list; dragging
/// helps when macOS fails to show the app clearly.
struct DraggableAppTileView: NSViewRepresentable {
    let appURL: URL

    func makeNSView(context: Context) -> DraggableAppTileNSView {
        DraggableAppTileNSView(appURL: appURL)
    }

    func updateNSView(_ nsView: DraggableAppTileNSView, context: Context) {
        nsView.appURL = appURL
    }
}

final class DraggableAppTileNSView: NSView, NSDraggingSource {
    var appURL: URL {
        didSet {
            iconView.image = NSWorkspace.shared.icon(forFile: appURL.path)
            pathField.stringValue = appURL.lastPathComponent
        }
    }

    private let iconView = NSImageView()
    private let titleField = NSTextField(labelWithString: "HushType")
    private let pathField: NSTextField
    private var dragStarted = false

    init(appURL: URL) {
        self.appURL = appURL
        self.pathField = NSTextField(labelWithString: appURL.lastPathComponent)
        super.init(frame: .zero)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func setup() {
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.82).cgColor
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.55).cgColor
        layer?.borderWidth = 0.5

        iconView.image = NSWorkspace.shared.icon(forFile: appURL.path)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false

        titleField.font = .systemFont(ofSize: 12, weight: .semibold)
        titleField.textColor = .labelColor
        titleField.lineBreakMode = .byTruncatingTail
        titleField.translatesAutoresizingMaskIntoConstraints = false

        pathField.font = .systemFont(ofSize: 10, weight: .regular)
        pathField.textColor = .secondaryLabelColor
        pathField.lineBreakMode = .byTruncatingMiddle
        pathField.translatesAutoresizingMaskIntoConstraints = false

        addSubview(iconView)
        addSubview(titleField)
        addSubview(pathField)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 24),
            iconView.heightAnchor.constraint(equalToConstant: 24),

            titleField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            titleField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            titleField.topAnchor.constraint(equalTo: topAnchor, constant: 8),

            pathField.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
            pathField.trailingAnchor.constraint(equalTo: titleField.trailingAnchor),
            pathField.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: 1),
        ])

        registerForDraggedTypes([.fileURL])
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        dragStarted = false
        NSCursor.closedHand.set()
    }

    override func mouseUp(with event: NSEvent) {
        NSCursor.openHand.set()
        dragStarted = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !dragStarted else { return }
        dragStarted = true

        let draggingItem = NSDraggingItem(pasteboardWriter: appURL as NSURL)
        draggingItem.setDraggingFrame(bounds, contents: dragImage())

        beginDraggingSession(with: [draggingItem], event: event, source: self)
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        dragStarted = false
        NSCursor.openHand.set()
    }

    private func dragImage() -> NSImage {
        let image = NSImage(size: bounds.size)
        guard let rep = bitmapImageRepForCachingDisplay(in: bounds) else {
            return NSWorkspace.shared.icon(forFile: appURL.path)
        }
        cacheDisplay(in: bounds, to: rep)
        image.addRepresentation(rep)
        return image
    }
}
