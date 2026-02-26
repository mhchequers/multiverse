import AppKit
@preconcurrency import Highlighter

@MainActor
enum SyntaxHighlighter {
    // Shared highlighter instance (expensive to create — loads JS engine)
    private static let highlighter: Highlighter? = {
        let h = Highlighter()
        h?.setTheme("atom-one-dark")
        return h
    }()

    static func languageName(for filename: String) -> String? {
        let ext = (filename as NSString).pathExtension.lowercased()
        switch ext {
        case "py": return "python"
        case "js": return "javascript"
        case "ts": return "typescript"
        case "jsx": return "jsx"
        case "tsx": return "tsx"
        case "sql": return "sql"
        case "md": return "markdown"
        case "yml", "yaml": return "yaml"
        case "json": return "json"
        case "html", "htm": return "html"
        case "css": return "css"
        case "swift": return "swift"
        case "sh", "bash", "zsh": return "bash"
        case "rb": return "ruby"
        case "rs": return "rust"
        case "go": return "go"
        case "java": return "java"
        case "toml": return "toml"
        case "xml": return "xml"
        case "jinja", "jinja2", "j2": return "django"
        default: return nil
        }
    }

    /// Highlight code and apply it to an NSTextView's text storage (for CodeEditorView).
    static func applyHighlighting(to textView: NSTextView, filename: String) {
        guard let highlighter = Self.highlighter,
              let language = languageName(for: filename),
              let textStorage = textView.textStorage else { return }

        let code = textView.string
        guard let highlighted = highlighter.highlight(code, as: language) else { return }

        let selectedRanges = textView.selectedRanges
        textStorage.beginEditing()
        textStorage.setAttributedString(highlighted)
        let fullRange = NSRange(location: 0, length: textStorage.length)
        textStorage.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular), range: fullRange)
        textStorage.endEditing()
        textView.selectedRanges = selectedRanges
    }

    /// Highlight full text and return per-line AttributedStrings (for SwiftUI Text views).
    static func highlightLines(_ text: String, filename: String) -> [AttributedString] {
        guard let highlighter = Self.highlighter,
              let language = languageName(for: filename),
              let highlighted = highlighter.highlight(text, as: language) else {
            // Fallback: return plain lines
            return text.split(separator: "\n", omittingEmptySubsequences: false).map {
                AttributedString(String($0))
            }
        }

        // Override font to monospaced system font
        let mutable = NSMutableAttributedString(attributedString: highlighted)
        let fullRange = NSRange(location: 0, length: mutable.length)
        mutable.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular), range: fullRange)

        // Split the attributed string by newlines
        let wholeString = mutable.string
        let lines = wholeString.split(separator: "\n", omittingEmptySubsequences: false)
        var result: [AttributedString] = []
        var location = 0

        for line in lines {
            let lineLength = line.count
            let range = NSRange(location: location, length: lineLength)
            let sub = mutable.attributedSubstring(from: range)
            // Convert NSAttributedString → SwiftUI AttributedString
            if let attrStr = try? AttributedString(sub, including: \.appKit) {
                result.append(attrStr)
            } else {
                result.append(AttributedString(String(line)))
            }
            location += lineLength + 1 // +1 for the newline
        }

        return result
    }
}
