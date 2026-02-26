import SwiftUI
import AppKit

struct CodeEditorView: NSViewRepresentable {
    @Binding var text: String
    let annotations: LineAnnotations
    let onSave: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(textBinding: $text)
    }

    func makeNSView(context: Context) -> NSView {
        let container = CodeEditorContainerView()

        // Scroll view (positioned to the right of the gutter)
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let textView = GutterTextView()
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.isRichText = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textColor = NSColor.textColor
        textView.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.3)
        textView.autoresizingMask = [.height]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        let largeSize = CGFloat(1e7)
        textView.textContainer?.containerSize = NSSize(width: largeSize, height: largeSize)
        textView.textContainer?.widthTracksTextView = false
        textView.maxSize = NSSize(width: largeSize, height: largeSize)
        textView.minSize = NSSize(width: 0, height: 0)

        textView.delegate = context.coordinator
        textView.string = text
        textView.annotations = annotations
        textView.saveAction = onSave

        scrollView.documentView = textView

        // Line number gutter (positioned at left edge, outside the scroll view)
        let gutterView = LineNumberGutterView(
            scrollView: scrollView, textView: textView, annotations: annotations
        )

        // Change marker overlay (positioned at right edge)
        let markerView = ChangeMarkerOverlay(annotations: annotations, textView: textView)

        container.addSubview(gutterView)
        container.addSubview(scrollView)
        container.addSubview(markerView)

        context.coordinator.textView = textView
        context.coordinator.scrollView = scrollView
        context.coordinator.gutterView = gutterView
        context.coordinator.markerView = markerView

        // Observe clip view frame changes so we recalculate text view width on resize
        scrollView.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.clipViewFrameChanged(_:)),
            name: NSView.frameDidChangeNotification,
            object: scrollView.contentView
        )

        // Defer frame adjustment until after AppKit completes layout
        DispatchQueue.main.async {
            Self.adjustTextViewFrame(textView, in: scrollView)
            scrollView.contentView.scroll(to: .zero)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }

        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        context.coordinator.textBinding = $text
        guard let textView = context.coordinator.textView,
              let scrollView = context.coordinator.scrollView else { return }

        if textView.string != text {
            let selectedRanges = textView.selectedRanges
            textView.string = text
            textView.selectedRanges = selectedRanges

            // Defer frame adjustment and scroll reset until after AppKit completes layout
            DispatchQueue.main.async {
                Self.adjustTextViewFrame(textView, in: scrollView)
                scrollView.contentView.scroll(to: .zero)
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
        }

        textView.annotations = annotations
        textView.saveAction = onSave

        if let gutterView = context.coordinator.gutterView {
            gutterView.annotations = annotations
            gutterView.needsDisplay = true
        }

        if let markerView = context.coordinator.markerView {
            markerView.annotations = annotations
            markerView.needsDisplay = true
        }
    }

    // MARK: - Text View Frame Management

    /// Manually set the text view's frame to match its content width.
    /// NSTextView's isHorizontallyResizable is unreliable on macOS 10.12+,
    /// so we calculate the used rect and set the frame explicitly.
    private static func adjustTextViewFrame(_ textView: NSTextView, in scrollView: NSScrollView) {
        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return }
        layoutManager.ensureLayout(for: textContainer)
        let usedRect = layoutManager.usedRect(for: textContainer)
        let clipSize = scrollView.contentView.bounds.size
        let padding = textContainer.lineFragmentPadding * 2 + 30
        let width = max(clipSize.width, usedRect.width + padding)
        let height = max(clipSize.height, usedRect.height)
        textView.setFrameSize(NSSize(width: width, height: height))
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var textBinding: Binding<String>
        var textView: GutterTextView?
        var scrollView: NSScrollView?
        var gutterView: LineNumberGutterView?
        var markerView: ChangeMarkerOverlay?

        init(textBinding: Binding<String>) {
            self.textBinding = textBinding
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            textBinding.wrappedValue = textView.string
        }

        @MainActor @objc func clipViewFrameChanged(_ notification: Notification) {
            guard let textView = textView, let scrollView = scrollView else { return }
            CodeEditorView.adjustTextViewFrame(textView, in: scrollView)
        }
    }
}

// MARK: - GutterTextView

class GutterTextView: NSTextView {
    var annotations = LineAnnotations()
    var saveAction: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "s" {
            saveAction?()
            return
        }
        super.keyDown(with: event)
    }
}

// MARK: - Line Number Gutter

class LineNumberGutterView: NSView {
    var annotations: LineAnnotations
    weak var scrollView: NSScrollView?
    weak var textView: NSTextView?

    override var isFlipped: Bool { true }

    private let gutterWidth: CGFloat = 55

    init(scrollView: NSScrollView, textView: NSTextView, annotations: LineAnnotations) {
        self.annotations = annotations
        self.scrollView = scrollView
        self.textView = textView
        super.init(frame: .zero)
        self.wantsLayer = true

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(contentDidChange(_:)),
            name: NSText.didChangeNotification,
            object: textView
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(contentDidChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    @objc private func contentDidChange(_ notification: Notification) {
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        // Draw gutter background
        NSColor.textBackgroundColor.withAlphaComponent(0.15).setFill()
        bounds.fill()

        guard let textView = textView,
              let scrollView = scrollView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return }

        let visibleRect = scrollView.contentView.bounds
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
        let charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)

        let text = textView.string as NSString
        var lineNumber = 1

        // Count lines before visible range
        text.enumerateSubstrings(in: NSRange(location: 0, length: charRange.location), options: [.byLines, .substringNotRequired]) { _, _, _, _ in
            lineNumber += 1
        }

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]

        text.enumerateSubstrings(in: charRange, options: [.byLines, .substringNotRequired]) { [self] _, substringRange, _, _ in
            let glyphIndex = layoutManager.glyphIndexForCharacter(at: substringRange.location)
            var lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
            lineRect.origin.y -= visibleRect.origin.y

            // Draw gutter color bar
            let gutterColor = self.gutterColor(for: lineNumber)
            if gutterColor != .clear {
                let barRect = NSRect(x: gutterWidth - 5, y: lineRect.origin.y, width: 3, height: lineRect.height)
                gutterColor.setFill()
                barRect.fill()
            }

            // Draw line number
            let numStr = "\(lineNumber)" as NSString
            let size = numStr.size(withAttributes: attrs)
            let y = lineRect.origin.y + (lineRect.height - size.height) / 2
            numStr.draw(at: NSPoint(x: gutterWidth - 12 - size.width, y: y), withAttributes: attrs)

            lineNumber += 1
        }
    }

    private func gutterColor(for lineNumber: Int) -> NSColor {
        if annotations.added.contains(lineNumber) {
            return NSColor.systemGreen
        } else if annotations.modified.contains(lineNumber) {
            return NSColor.systemBlue
        }
        return .clear
    }
}

// MARK: - Container Layout

class CodeEditorContainerView: NSView {
    private let gutterWidth: CGFloat = 55
    private let markerWidth: CGFloat = 10

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        for subview in subviews {
            if subview is LineNumberGutterView {
                subview.frame = NSRect(x: 0, y: 0, width: gutterWidth, height: bounds.height)
            } else if subview is NSScrollView {
                subview.frame = NSRect(
                    x: gutterWidth, y: 0,
                    width: bounds.width - gutterWidth - markerWidth,
                    height: bounds.height
                )
            } else if subview is ChangeMarkerOverlay {
                subview.frame = NSRect(
                    x: bounds.width - markerWidth, y: 0,
                    width: markerWidth, height: bounds.height
                )
            }
        }
    }
}

// MARK: - Change Marker Overlay (scrollbar strip)

class ChangeMarkerOverlay: NSView {
    var annotations: LineAnnotations
    weak var textView: GutterTextView?

    init(annotations: LineAnnotations, textView: GutterTextView) {
        self.annotations = annotations
        self.textView = textView
        super.init(frame: .zero)
        self.wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    override var allowsVibrancy: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let textView = textView else { return }
        let totalLines = max(1, textView.string.components(separatedBy: "\n").count)
        let height = bounds.height

        // Track background
        NSColor.white.withAlphaComponent(0.03).setFill()
        bounds.fill()

        // Draw markers
        let allChanged = annotations.added.union(annotations.modified)
        guard !allChanged.isEmpty else { return }

        // Group consecutive lines into regions
        let sorted = allChanged.sorted()
        var regions: [(start: Int, count: Int, color: NSColor)] = []
        var i = 0
        while i < sorted.count {
            let start = sorted[i]
            let color = annotations.added.contains(start) ? NSColor.systemGreen : NSColor.systemBlue
            var count = 1
            while i + count < sorted.count && sorted[i + count] == start + count {
                count += 1
            }
            regions.append((start, count, color))
            i += count
        }

        for region in regions {
            let y = (CGFloat(region.start - 1) / CGFloat(totalLines)) * height
            let h = max(2, (CGFloat(region.count) / CGFloat(totalLines)) * height)
            let markerRect = NSRect(x: 0, y: y, width: bounds.width, height: h)
            region.color.withAlphaComponent(0.8).setFill()
            markerRect.fill()
        }
    }
}
