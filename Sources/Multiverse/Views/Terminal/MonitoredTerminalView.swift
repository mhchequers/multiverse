import AppKit
import SwiftTerm

class MonitoredTerminalView: LocalProcessTerminalView {
    private(set) var lastOutputTime: Date?
    private(set) var isProcessRunning = true
    var workingDirectory: String?
    var onOpenFilePath: ((String) -> Void)?
    nonisolated(unsafe) private var eventMonitor: Any?
    private var hoveredFilePath: String?
    private var isCommandHeld = false

    // MARK: - Cell Dimensions

    private func cellDimensions() -> (width: CGFloat, height: CGFloat)? {
        let terminal = getTerminal()
        let rows = terminal.rows
        let cols = terminal.cols
        guard rows > 0, cols > 0 else { return nil }
        let optimal = getOptimalFrameSize()
        let cellHeight = optimal.height / CGFloat(rows)
        // optimal.width includes scroller; subtract it to get just the text area
        let scrollerW = NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
        let cellWidth = (optimal.width - scrollerW) / CGFloat(cols)
        return (cellWidth, cellHeight)
    }

    private func terminalPosition(for locationInWindow: NSPoint) -> (row: Int, col: Int)? {
        let terminal = getTerminal()
        let rows = terminal.rows
        let cols = terminal.cols
        guard let cell = cellDimensions() else {
            return nil
        }

        let localPoint = convert(locationInWindow, from: nil)
        let col = Int(localPoint.x / cell.width)
        // NSView origin is bottom-left, terminal row 0 is top
        let row = Int((frame.height - localPoint.y) / cell.height)

        guard row >= 0, row < rows, col >= 0, col < cols else { return nil }
        return (row, col)
    }

    // MARK: - Event Monitor

    func installCmdClickMonitor() {
        _ = Self.installCursorOverrides
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseUp, .mouseMoved, .flagsChanged]
        ) { [weak self] event in
            guard let self else { return event }

            switch event.type {
            case .mouseMoved:
                self.handleMouseMoved(event)
                return event

            case .flagsChanged:
                self.handleFlagsChanged(event)
                return event

            case .leftMouseUp:
                guard event.modifierFlags.contains(.command),
                      event.clickCount == 1 else {
                    return event
                }
                let locationInView = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(locationInView),
                      self.window == event.window else {
                    return event
                }
                if let path = self.hoveredFilePath {
                    self.onOpenFilePath?(path)
                    return nil
                }
                if self.tryOpenFilePath(from: event) {
                    return nil
                }
                return event

            default:
                return event
            }
        }
    }

    // MARK: - Cursor Rect Overrides
    //
    // SwiftTerm's TerminalView overrides resetCursorRects/cursorUpdate as non-open,
    // so we can't use Swift `override`. Instead, use the ObjC runtime to add our
    // implementations on this subclass, which take priority over the superclass's.

    private static let installCursorOverrides: Void = {
        typealias ResetBlock = @convention(block) (AnyObject) -> Void
        let resetBlock: ResetBlock = { obj in
            guard let view = obj as? MonitoredTerminalView else { return }
            if view.isCommandHeld, view.hoveredFilePath != nil {
                view.addCursorRect(view.bounds, cursor: .pointingHand)
            } else {
                view.addCursorRect(view.bounds, cursor: .iBeam)
            }
        }
        let resetSel = #selector(NSView.resetCursorRects)
        let resetIMP = imp_implementationWithBlock(resetBlock as Any)
        let _ = class_addMethod(MonitoredTerminalView.self, resetSel, resetIMP, "v@:")

        typealias CursorBlock = @convention(block) (AnyObject, NSEvent) -> Void
        let cursorBlock: CursorBlock = { obj, event in
            guard let view = obj as? MonitoredTerminalView else { return }
            if view.isCommandHeld, view.hoveredFilePath != nil {
                NSCursor.pointingHand.set()
            } else {
                NSCursor.iBeam.set()
            }
        }
        let cursorSel = #selector(NSResponder.cursorUpdate(with:))
        let cursorIMP = imp_implementationWithBlock(cursorBlock as Any)
        let _ = class_addMethod(MonitoredTerminalView.self, cursorSel, cursorIMP, "v@:@")
    }()

    deinit {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    // MARK: - Hover Detection

    private func handleMouseMoved(_ event: NSEvent) {
        guard isCommandHeld else { return }
        guard self.window == event.window else { return }
        let locationInView = convert(event.locationInWindow, from: nil)
        guard bounds.contains(locationInView) else {
            clearHoverState()
            return
        }
        updateHover(at: event.locationInWindow)
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        let cmdHeld = event.modifierFlags.contains(.command)
        if cmdHeld && !isCommandHeld {
            isCommandHeld = true
            // Cmd just pressed — check hover at current mouse location
            if let window = self.window {
                let mouseInWindow = window.mouseLocationOutsideOfEventStream
                let locationInView = convert(mouseInWindow, from: nil)
                if bounds.contains(locationInView) {
                    updateHover(at: mouseInWindow)
                }
            }
        } else if !cmdHeld && isCommandHeld {
            isCommandHeld = false
            clearHoverState()
        }
    }

    private func updateHover(at locationInWindow: NSPoint) {
        guard let pos = terminalPosition(for: locationInWindow) else {
            clearHoverState()
            return
        }

        let terminal = getTerminal()
        let cols = terminal.cols
        guard let bufferLine = terminal.getLine(row: pos.row) else {
            clearHoverState()
            return
        }
        let lineText = bufferLine.translateToString(trimRight: true, startCol: 0, endCol: cols)
            .replacingOccurrences(of: "\0", with: " ")
        guard !lineText.isEmpty,
              let path = extractFilePath(from: lineText, around: pos.col),
              let resolved = resolveFilePath(path) else {
            clearHoverState()
            return
        }

        hoveredFilePath = resolved
        NSCursor.pointingHand.set()
        window?.invalidateCursorRects(for: self)
    }

    private func clearHoverState() {
        if hoveredFilePath != nil {
            hoveredFilePath = nil
            NSCursor.arrow.set()
            window?.invalidateCursorRects(for: self)
        }
    }

    // MARK: - Click Handling

    private func tryOpenFilePath(from event: NSEvent) -> Bool {
        guard let pos = terminalPosition(for: event.locationInWindow) else { return false }

        let terminal = getTerminal()
        let cols = terminal.cols
        guard let bufferLine = terminal.getLine(row: pos.row) else { return false }
        let lineText = bufferLine.translateToString(trimRight: true, startCol: 0, endCol: cols)
            .replacingOccurrences(of: "\0", with: " ")
        guard !lineText.isEmpty else { return false }

        guard let path = extractFilePath(from: lineText, around: pos.col) else { return false }
        guard let resolved = resolveFilePath(path) else { return false }

        onOpenFilePath?(resolved)
        return true
    }

    private func extractFilePath(from line: String, around col: Int) -> String? {
        let chars = Array(line)
        guard col < chars.count else { return nil }

        let stopChars: Set<Character> = [" ", "\t", "'", "\"", "(", ")", "[", "]", "{", "}", "<", ">", "|", ";", ","]

        // Scan left
        var left = col
        while left > 0 {
            let prev = chars[left - 1]
            if stopChars.contains(prev) { break }
            left -= 1
        }

        // Scan right
        var right = col
        while right < chars.count - 1 {
            let next = chars[right + 1]
            if stopChars.contains(next) { break }
            right += 1
        }

        var candidate = String(chars[left...right])
        guard !candidate.isEmpty else { return nil }

        // Strip trailing :line:col suffixes (e.g. file.swift:10:5)
        candidate = candidate.replacingOccurrences(
            of: #"(:\d+)+:?$"#,
            with: "",
            options: .regularExpression
        )

        // Strip trailing sentence punctuation (e.g. "file.swift." at end of sentence)
        while let last = candidate.last, ".!?:".contains(last) {
            candidate.removeLast()
        }

        // Must contain at least one path separator or dot to look like a file path
        guard candidate.contains("/") || candidate.contains(".") else { return nil }

        // Reject if it looks like a flag
        guard !candidate.hasPrefix("-") else { return nil }

        return candidate
    }

    private func resolveFilePath(_ path: String) -> String? {
        let fm = FileManager.default

        // Try as absolute path
        if path.hasPrefix("/") {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue {
                // Convert to relative if under working directory
                if let wd = workingDirectory {
                    let wdSuffix = wd.hasSuffix("/") ? wd : wd + "/"
                    if path.hasPrefix(wdSuffix) {
                        return String(path.dropFirst(wdSuffix.count))
                    }
                }
                return path
            }
        }

        // Try relative to working directory
        if let wd = workingDirectory {
            let fullPath = (wd as NSString).appendingPathComponent(path)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: fullPath, isDirectory: &isDir), !isDir.boolValue {
                return path
            }
        }

        return nil
    }

    override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice)
        DispatchQueue.main.async {
            self.lastOutputTime = Date()
        }
    }

    override func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        super.processTerminated(source, exitCode: exitCode)
        DispatchQueue.main.async {
            self.isProcessRunning = false
        }
    }

    func terminateProcessGroup() {
        let pid = process.shellPid
        guard pid != 0 else { return }
        kill(pid, SIGHUP)
        terminate()
    }
}
