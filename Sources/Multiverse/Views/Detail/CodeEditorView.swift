import SwiftUI
import AppKit

struct CodeEditorView: NSViewRepresentable {
    @Binding var text: String
    let filename: String
    let annotations: LineAnnotations
    let onSave: () -> Void
    var onQuickOpen: (() -> Void)? = nil
    let initialScrollOffset: CGPoint
    let onScrollOffsetChanged: (CGPoint) -> Void

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
        textView.isRichText = true
        textView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textColor = NSColor.textColor
        textView.backgroundColor = .clear
        textView.autoresizingMask = [.height]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        let largeSize = CGFloat(1e7)
        textView.textContainer?.containerSize = NSSize(width: largeSize, height: largeSize)
        textView.textContainer?.widthTracksTextView = false
        textView.maxSize = NSSize(width: largeSize, height: largeSize)
        textView.minSize = NSSize(width: 0, height: 0)

        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.delegate = context.coordinator
        textView.string = text
        textView.annotations = annotations
        textView.saveAction = onSave
        textView.onQuickOpen = onQuickOpen
        textView.onFindBarTriggered = { [weak coordinator = context.coordinator] in
            coordinator?.attachToFindBar()
        }

        scrollView.documentView = textView

        // Line number gutter (positioned at left edge, outside the scroll view)
        let gutterView = LineNumberGutterView(
            scrollView: scrollView, textView: textView, annotations: annotations
        )

        // Change marker overlay (positioned at right edge)
        let markerView = ChangeMarkerOverlay(annotations: annotations, textView: textView, scrollView: scrollView)

        container.addSubview(gutterView)
        container.addSubview(scrollView)
        container.addSubview(markerView)

        context.coordinator.textView = textView
        context.coordinator.scrollView = scrollView
        context.coordinator.gutterView = gutterView
        context.coordinator.markerView = markerView
        context.coordinator.filename = filename

        // Apply initial syntax highlighting
        SyntaxHighlighter.applyHighlighting(to: textView, filename: filename)

        // Observe clip view frame changes so we recalculate text view width on resize
        scrollView.contentView.postsFrameChangedNotifications = true
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.clipViewFrameChanged(_:)),
            name: NSView.frameDidChangeNotification,
            object: scrollView.contentView
        )
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.scrollViewDidScroll(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
        context.coordinator.onScrollOffsetChanged = onScrollOffsetChanged

        // Defer frame adjustment until after AppKit completes layout
        let restoreOffset = initialScrollOffset
        DispatchQueue.main.async {
            Self.adjustTextViewFrame(textView, in: scrollView)
            context.coordinator.isRestoringScroll = true
            scrollView.contentView.scroll(to: restoreOffset)
            scrollView.reflectScrolledClipView(scrollView.contentView)
            context.coordinator.isRestoringScroll = false
        }

        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        context.coordinator.textBinding = $text
        context.coordinator.filename = filename
        context.coordinator.onScrollOffsetChanged = onScrollOffsetChanged
        guard let textView = context.coordinator.textView,
              let scrollView = context.coordinator.scrollView else { return }

        if textView.string != text {
            let selectedRanges = textView.selectedRanges
            textView.string = text
            textView.selectedRanges = selectedRanges

            // Apply syntax highlighting on external text change
            SyntaxHighlighter.applyHighlighting(to: textView, filename: filename)

            // Defer frame adjustment and scroll reset until after AppKit completes layout
            DispatchQueue.main.async {
                Self.adjustTextViewFrame(textView, in: scrollView)
                scrollView.contentView.scroll(to: .zero)
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
        }

        textView.annotations = annotations
        textView.saveAction = onSave
        textView.onQuickOpen = onQuickOpen

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
        var filename: String = ""
        var textView: GutterTextView?
        var scrollView: NSScrollView?
        var gutterView: LineNumberGutterView?
        var markerView: ChangeMarkerOverlay?
        var highlightTask: DispatchWorkItem?
        var onScrollOffsetChanged: ((CGPoint) -> Void)?
        var isRestoringScroll = false

        // Find bar observation
        var findSearchField: NSSearchField?
        var findSearchFieldObserver: Any?
        var findBarDismissalTimer: Timer?
        var lastSearchText: String = ""

        // Selection occurrence highlighting
        var selectionHighlightTask: DispatchWorkItem?
        var selectionHighlightRanges: [NSRange] = []

        init(textBinding: Binding<String>) {
            self.textBinding = textBinding
        }

        deinit {
            if let observer = findSearchFieldObserver {
                NotificationCenter.default.removeObserver(observer)
            }
            findBarDismissalTimer?.invalidate()
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            textBinding.wrappedValue = textView.string

            // Debounced re-highlighting
            highlightTask?.cancel()
            let filename = self.filename
            let task = DispatchWorkItem {
                SyntaxHighlighter.applyHighlighting(to: textView, filename: filename)
            }
            highlightTask = task
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: task)

            // Re-search if find bar is active
            if findSearchField?.window != nil {
                lastSearchText = ""
                searchTextDidChange()
            }
        }

        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
            guard let replacement = replacementString, replacement == "\n" else { return true }

            let text = textView.string as NSString
            let lineRange = text.lineRange(for: NSRange(location: affectedCharRange.location, length: 0))
            let line = text.substring(with: lineRange)

            // Extract leading whitespace from the current line
            var indent = ""
            for char in line {
                if char == " " || char == "\t" {
                    indent.append(char)
                } else {
                    break
                }
            }

            guard !indent.isEmpty else { return true }

            let indented = "\n" + indent
            textView.insertText(indented, replacementRange: affectedCharRange)
            return false
        }

        @MainActor @objc func clipViewFrameChanged(_ notification: Notification) {
            guard let textView = textView, let scrollView = scrollView else { return }
            CodeEditorView.adjustTextViewFrame(textView, in: scrollView)
        }

        @MainActor @objc func scrollViewDidScroll(_ notification: Notification) {
            guard !isRestoringScroll,
                  let scrollView = scrollView else { return }
            onScrollOffsetChanged?(scrollView.contentView.bounds.origin)
        }

        // MARK: - Find Bar Observation

        @MainActor func attachToFindBar() {
            if findSearchField?.window != nil { return }

            DispatchQueue.main.async { [weak self] in
                guard let self, let scrollView = self.scrollView else { return }
                guard let searchField = self.findSearchFieldIn(scrollView) else { return }
                self.findSearchField = searchField

                self.findSearchFieldObserver = NotificationCenter.default.addObserver(
                    forName: NSControl.textDidChangeNotification,
                    object: searchField,
                    queue: .main
                ) { [weak self] _ in
                    DispatchQueue.main.async {
                        self?.searchTextDidChange()
                    }
                }

                self.searchTextDidChange()

                self.findBarDismissalTimer?.invalidate()
                self.findBarDismissalTimer = Timer.scheduledTimer(
                    withTimeInterval: 0.5, repeats: true
                ) { [weak self] _ in
                    DispatchQueue.main.async {
                        self?.checkFindBarDismissed()
                    }
                }
            }
        }

        @MainActor private func findSearchFieldIn(_ view: NSView) -> NSSearchField? {
            for subview in view.subviews {
                if let sf = subview as? NSSearchField { return sf }
                if let found = findSearchFieldIn(subview) { return found }
            }
            return nil
        }

        @MainActor func searchTextDidChange() {
            guard let searchField = findSearchField,
                  let textView = textView,
                  let markerView = markerView,
                  let layoutManager = textView.layoutManager else { return }

            let searchText = searchField.stringValue
            guard searchText != lastSearchText else { return }
            lastSearchText = searchText

            let text = textView.string as NSString
            let fullRange = NSRange(location: 0, length: text.length)

            // Clear previous highlights
            layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: fullRange)

            guard !searchText.isEmpty else {
                markerView.findMatchLines = []
                markerView.needsDisplay = true
                return
            }

            var matchLines = Set<Int>()
            var matchRanges: [NSRange] = []

            // Pre-build line start offsets for efficient line number lookup
            var lineStarts = [0]
            let raw = textView.string
            for (i, char) in raw.enumerated() {
                if char == "\n" { lineStarts.append(i + 1) }
            }

            var searchRange = NSRange(location: 0, length: text.length)
            while searchRange.location < text.length {
                let found = text.range(of: searchText, options: .caseInsensitive, range: searchRange)
                if found.location == NSNotFound { break }

                matchRanges.append(found)

                // Binary search for line number
                var lo = 0, hi = lineStarts.count - 1
                while lo < hi {
                    let mid = (lo + hi + 1) / 2
                    if lineStarts[mid] <= found.location { lo = mid } else { hi = mid - 1 }
                }
                matchLines.insert(lo + 1) // 1-based

                searchRange.location = found.location + 1
                searchRange.length = text.length - searchRange.location
            }

            // Apply text highlights
            let highlightColor = NSColor.systemYellow.withAlphaComponent(0.3)
            for range in matchRanges {
                layoutManager.addTemporaryAttribute(.backgroundColor, value: highlightColor, forCharacterRange: range)
            }

            markerView.findMatchLines = matchLines
            markerView.needsDisplay = true
        }

        @MainActor func checkFindBarDismissed() {
            guard let scrollView = scrollView else {
                clearFindMatchMarkers()
                return
            }
            if !scrollView.isFindBarVisible {
                clearFindMatchMarkers()
            }
        }

        @MainActor func clearFindMatchMarkers() {
            if let observer = findSearchFieldObserver {
                NotificationCenter.default.removeObserver(observer)
                findSearchFieldObserver = nil
            }
            findBarDismissalTimer?.invalidate()
            findBarDismissalTimer = nil
            findSearchField = nil
            lastSearchText = ""
            markerView?.findMatchLines = []
            markerView?.needsDisplay = true
            if let layoutManager = textView?.layoutManager, let text = textView?.string {
                layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: NSRange(location: 0, length: (text as NSString).length))
            }
        }

        // MARK: - Selection Occurrence Highlighting

        func textViewDidChangeSelection(_ notification: Notification) {
            selectionHighlightTask?.cancel()
            let task = DispatchWorkItem { [weak self] in
                self?.updateSelectionHighlights()
            }
            selectionHighlightTask = task
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: task)
        }

        @MainActor private func updateSelectionHighlights() {
            guard let textView = textView,
                  let markerView = markerView,
                  let layoutManager = textView.layoutManager else { return }

            // Clear previous selection highlights
            clearSelectionHighlights()

            // Don't highlight if find bar is active
            if findSearchField?.window != nil { return }

            // Get selected text
            let selectedRange = textView.selectedRange()
            guard selectedRange.length > 0 else { return }

            let text = textView.string as NSString
            let selectedText = text.substring(with: selectedRange)

            // Must be a single word (no whitespace/newlines), at least 2 chars
            let trimmed = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count >= 2, trimmed == selectedText, !selectedText.contains("\n") else { return }

            // Build line start offsets for line number lookup
            var lineStarts = [0]
            let raw = textView.string
            for (i, char) in raw.enumerated() {
                if char == "\n" { lineStarts.append(i + 1) }
            }

            // Find all whole-word occurrences (case-sensitive)
            var matchLines = Set<Int>()
            var matchRanges: [NSRange] = []

            var searchRange = NSRange(location: 0, length: text.length)
            while searchRange.location < text.length {
                let found = text.range(of: selectedText, options: [], range: searchRange)
                if found.location == NSNotFound { break }

                // Check word boundaries
                let before = found.location > 0 ? text.character(at: found.location - 1) : 0x20
                let after = (found.location + found.length < text.length) ? text.character(at: found.location + found.length) : 0x20
                let isWordBoundaryBefore = !CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_")).contains(UnicodeScalar(before)!)
                let isWordBoundaryAfter = !CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_")).contains(UnicodeScalar(after)!)

                if isWordBoundaryBefore && isWordBoundaryAfter {
                    // Binary search for line number (always include in markers)
                    var lo = 0, hi = lineStarts.count - 1
                    while lo < hi {
                        let mid = (lo + hi + 1) / 2
                        if lineStarts[mid] <= found.location { lo = mid } else { hi = mid - 1 }
                    }
                    matchLines.insert(lo + 1)

                    // Only highlight non-selected occurrences (selected text is already visually distinct)
                    if found.location != selectedRange.location || found.length != selectedRange.length {
                        matchRanges.append(found)
                    }
                }

                searchRange.location = found.location + 1
                searchRange.length = text.length - searchRange.location
            }

            // Apply subtle background highlights
            let highlightColor = NSColor.white.withAlphaComponent(0.15)
            for range in matchRanges {
                layoutManager.addTemporaryAttribute(.backgroundColor, value: highlightColor, forCharacterRange: range)
            }
            selectionHighlightRanges = matchRanges

            markerView.selectionMatchLines = matchLines
            markerView.needsDisplay = true
        }

        @MainActor private func clearSelectionHighlights() {
            guard let textView = textView,
                  let layoutManager = textView.layoutManager,
                  let markerView = markerView else { return }

            for range in selectionHighlightRanges {
                // Only remove if still within text bounds
                if range.location + range.length <= (textView.string as NSString).length {
                    layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: range)
                }
            }
            selectionHighlightRanges = []
            markerView.selectionMatchLines = []
            markerView.needsDisplay = true
        }
    }
}

// MARK: - GutterTextView

class GutterTextView: NSTextView {
    var annotations = LineAnnotations()
    var saveAction: (() -> Void)?
    var onQuickOpen: (() -> Void)?
    var onFindBarTriggered: (() -> Void)?

    override func insertTab(_ sender: Any?) {
        insertText("    ", replacementRange: selectedRange())
    }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "s" {
            saveAction?()
            return
        }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if let chars = event.charactersIgnoringModifiers {
            switch (flags, chars) {
            case (.command, "f"):
                triggerFindAction(.showFindInterface)
                onFindBarTriggered?()
                return true
            case (.command, "g"):
                triggerFindAction(.nextMatch)
                return true
            case ([.command, .shift], "G"), ([.command, .shift], "g"):
                triggerFindAction(.previousMatch)
                return true
            case (.command, "e"):
                triggerFindAction(.setSearchString)
                return true
            case (.command, "p"):
                onQuickOpen?()
                return true
            default:
                break
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    private func triggerFindAction(_ action: NSTextFinder.Action) {
        let sender = NSMenuItem()
        sender.tag = action.rawValue
        performTextFinderAction(sender)
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

            // Draw deletion triangle (red wedge at bottom edge of line where deletions occurred)
            if annotations.deleted.contains(lineNumber) {
                let triangleSize: CGFloat = 5
                let triangleY = lineRect.origin.y + lineRect.height - 1
                let triangleX = gutterWidth - 5
                let path = NSBezierPath()
                path.move(to: NSPoint(x: triangleX, y: triangleY))
                path.line(to: NSPoint(x: triangleX + triangleSize, y: triangleY))
                path.line(to: NSPoint(x: triangleX, y: triangleY - triangleSize))
                path.close()
                NSColor.systemRed.setFill()
                path.fill()
            } else if lineNumber == 1 && annotations.deleted.contains(0) {
                // Deletion before line 1: draw triangle at top of first line
                let triangleSize: CGFloat = 5
                let triangleY = lineRect.origin.y + 1
                let triangleX = gutterWidth - 5
                let path = NSBezierPath()
                path.move(to: NSPoint(x: triangleX, y: triangleY))
                path.line(to: NSPoint(x: triangleX + triangleSize, y: triangleY))
                path.line(to: NSPoint(x: triangleX, y: triangleY + triangleSize))
                path.close()
                NSColor.systemRed.setFill()
                path.fill()
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
    var findMatchLines: Set<Int> = []
    var selectionMatchLines: Set<Int> = []
    weak var textView: GutterTextView?
    weak var scrollView: NSScrollView?

    override var isFlipped: Bool { true }

    init(annotations: LineAnnotations, textView: GutterTextView, scrollView: NSScrollView) {
        self.annotations = annotations
        self.textView = textView
        self.scrollView = scrollView
        super.init(frame: .zero)
        self.wantsLayer = true

        // Redraw when scroller layout changes (e.g., find bar appears/disappears)
        if let scroller = scrollView.verticalScroller {
            scroller.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(
                self, selector: #selector(scrollerFrameChanged(_:)),
                name: NSView.frameDidChangeNotification, object: scroller
            )
        }
    }

    @objc private func scrollerFrameChanged(_ notification: Notification) {
        needsDisplay = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    override var allowsVibrancy: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let textView = textView else { return }
        let totalLines = max(1, textView.string.components(separatedBy: "\n").count)

        // Determine the Y range that matches the scrollbar's actual track area
        var trackMinY: CGFloat = 0
        var trackHeight: CGFloat = bounds.height

        if let scroller = scrollView?.verticalScroller {
            let knobSlot = scroller.rect(for: .knobSlot)
            if let sv = scrollView {
                let converted = sv.convert(knobSlot, from: scroller)
                trackMinY = converted.origin.y
                trackHeight = converted.size.height
            }
        }

        // Track background
        NSColor.white.withAlphaComponent(0.03).setFill()
        bounds.fill()

        // Draw selection occurrence markers (behind everything else)
        if !selectionMatchLines.isEmpty {
            let sorted = selectionMatchLines.sorted()
            var regions: [(start: Int, count: Int)] = []
            var i = 0
            while i < sorted.count {
                let start = sorted[i]
                var count = 1
                while i + count < sorted.count && sorted[i + count] == start + count {
                    count += 1
                }
                regions.append((start, count))
                i += count
            }
            for region in regions {
                let y = trackMinY + (CGFloat(region.start - 1) / CGFloat(totalLines)) * trackHeight
                let h = max(2, (CGFloat(region.count) / CGFloat(totalLines)) * trackHeight)
                let markerRect = NSRect(x: 0, y: y, width: bounds.width, height: h)
                NSColor.white.withAlphaComponent(0.45).setFill()
                markerRect.fill()
            }
        }

        // Draw find match markers (behind git markers)
        if !findMatchLines.isEmpty {
            let sorted = findMatchLines.sorted()
            var regions: [(start: Int, count: Int)] = []
            var i = 0
            while i < sorted.count {
                let start = sorted[i]
                var count = 1
                while i + count < sorted.count && sorted[i + count] == start + count {
                    count += 1
                }
                regions.append((start, count))
                i += count
            }
            for region in regions {
                let y = trackMinY + (CGFloat(region.start - 1) / CGFloat(totalLines)) * trackHeight
                let h = max(2, (CGFloat(region.count) / CGFloat(totalLines)) * trackHeight)
                let markerRect = NSRect(x: 0, y: y, width: bounds.width, height: h)
                NSColor.systemOrange.withAlphaComponent(0.7).setFill()
                markerRect.fill()
            }
        }

        // Draw markers for added/modified
        let allChanged = annotations.added.union(annotations.modified)

        if !allChanged.isEmpty {
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
                let y = trackMinY + (CGFloat(region.start - 1) / CGFloat(totalLines)) * trackHeight
                let h = max(2, (CGFloat(region.count) / CGFloat(totalLines)) * trackHeight)
                let markerRect = NSRect(x: 0, y: y, width: bounds.width, height: h)
                region.color.withAlphaComponent(0.8).setFill()
                markerRect.fill()
            }
        }

        // Draw markers for deletions (small red dots)
        for deletedLine in annotations.deleted {
            let linePos = max(0, deletedLine)
            let y = trackMinY + (CGFloat(linePos) / CGFloat(totalLines)) * trackHeight
            let markerRect = NSRect(x: 1, y: y, width: bounds.width - 2, height: 2)
            NSColor.systemRed.withAlphaComponent(0.8).setFill()
            markerRect.fill()
        }
    }
}
