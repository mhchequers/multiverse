import AppKit
@preconcurrency import Highlighter

@MainActor
enum SyntaxHighlighter {
    // Shared highlighter instance (expensive to create — loads JS engine)
    private static let highlighter: Highlighter? = {
        let h = Highlighter()
        h?.setTheme("vs2015")
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

    // VS Code Dark+ exact colors
    private static let vsPurple = NSColor(red: 0xC5/255.0, green: 0x86/255.0, blue: 0xC0/255.0, alpha: 1.0)    // #C586C0 keywords
    private static let vsBlue = NSColor(red: 0x56/255.0, green: 0x9C/255.0, blue: 0xD6/255.0, alpha: 1.0)      // #569CD6 constants
    private static let vsTeal = NSColor(red: 0x4E/255.0, green: 0xC9/255.0, blue: 0xB0/255.0, alpha: 1.0)      // #4EC9B0 types/classes
    private static let vsYellow = NSColor(red: 0xDC/255.0, green: 0xDC/255.0, blue: 0xAA/255.0, alpha: 1.0)    // #DCDCAA functions
    private static let vsLightBlue = NSColor(red: 0x9C/255.0, green: 0xDC/255.0, blue: 0xFE/255.0, alpha: 1.0) // #9CDCFE variables/params
    private static let vsString = NSColor(red: 0xCE/255.0, green: 0x91/255.0, blue: 0x78/255.0, alpha: 1.0)    // #CE9178 strings
    private static let vsComment = NSColor(red: 0x6A/255.0, green: 0x99/255.0, blue: 0x55/255.0, alpha: 1.0)   // #6A9955 comments
    private static let vsNumber = NSColor(red: 0xB5/255.0, green: 0xCE/255.0, blue: 0xA8/255.0, alpha: 1.0)    // #B5CEA8 numbers
    private static let vsBaseText = NSColor(red: 0xD4/255.0, green: 0xD4/255.0, blue: 0xD4/255.0, alpha: 1.0)  // #D4D4D4 base text

    // vs2015 → VS Code Dark+ color remap table
    private static let colorRemap: [(from: (CGFloat, CGFloat, CGFloat), to: NSColor)] = [
        ((0x56/255.0, 0x9C/255.0, 0xD6/255.0), vsPurple),    // keywords/literals: blue → purple
        ((0xD6/255.0, 0x9D/255.0, 0x85/255.0), vsString),     // strings
        ((0x57/255.0, 0xA6/255.0, 0x4A/255.0), vsComment),    // comments
        ((0xB8/255.0, 0xD7/255.0, 0xA3/255.0), vsNumber),     // numbers
        ((0xDC/255.0, 0xDC/255.0, 0xDC/255.0), vsBaseText),   // base text
    ]

    // Regex patterns (compiled once)
    private static let selfPattern = try! NSRegularExpression(pattern: "\\bself\\b")
    private static let constantsPattern = try! NSRegularExpression(pattern: "\\b(True|False|None)\\b")
    private static let typeHintPattern = try! NSRegularExpression(pattern: "(?<=:\\s{0,4})([A-Z]\\w+)")
    private static let returnTypePattern = try! NSRegularExpression(pattern: "(?<=->\\s{0,4})([A-Z]\\w+)")
    private static let builtinTypePattern = try! NSRegularExpression(pattern: "\\b(dict|list|str|int|float|bool|set|tuple|type|Any|Optional|Union|Type|List|Dict|Set|Tuple|Callable|Iterator|Generator|Sequence|Mapping|Iterable)\\b")
    private static let funcDefPattern = try! NSRegularExpression(pattern: "(?<=\\bdef\\s)(\\w+)")
    private static let classNamePattern = try! NSRegularExpression(pattern: "(?<=\\bclass\\s)(\\w+)")
    private static let superclassPattern = try! NSRegularExpression(pattern: "(?<=\\bclass\\s\\w{1,80}\\()([^)]+)")
    private static let methodCallPattern = try! NSRegularExpression(pattern: "(?<=\\.)(\\w+)(?=\\()")
    private static let dottedClassPattern = try! NSRegularExpression(pattern: "(?<=\\.)(\\b[A-Z]\\w+)")
    private static let varAssignPattern = try! NSRegularExpression(pattern: "^(\\s+)(\\w+)(?=\\s*[=:])", options: .anchorsMatchLines)

    /// Remap vs2015 colors to VS Code Dark+ colors
    private static func remapColors(_ textStorage: NSMutableAttributedString) {
        let fullRange = NSRange(location: 0, length: textStorage.length)
        var replacements: [(NSRange, NSColor)] = []
        textStorage.enumerateAttribute(.foregroundColor, in: fullRange) { value, range, _ in
            guard let color = value as? NSColor,
                  let srgb = color.usingColorSpace(.sRGB) else { return }
            let r = srgb.redComponent, g = srgb.greenComponent, b = srgb.blueComponent
            for (from, to) in colorRemap {
                if abs(r - from.0) < 0.02 && abs(g - from.1) < 0.02 && abs(b - from.2) < 0.02 {
                    replacements.append((range, to))
                    break
                }
            }
        }
        for (range, color) in replacements {
            textStorage.addAttribute(.foregroundColor, value: color, range: range)
        }
    }

    /// Check if a character position is inside a string or comment (already colored — after remap)
    private static func isStringOrComment(_ textStorage: NSMutableAttributedString, at location: Int) -> Bool {
        let attrs = textStorage.attributes(at: location, effectiveRange: nil)
        guard let color = attrs[.foregroundColor] as? NSColor else { return false }
        guard let srgb = color.usingColorSpace(.sRGB) else { return false }
        let r = srgb.redComponent, g = srgb.greenComponent, b = srgb.blueComponent
        // VS Code Dark+ string color: #CE9178
        let isString = abs(r - 0xCE/255.0) < 0.02 && abs(g - 0x91/255.0) < 0.02 && abs(b - 0x78/255.0) < 0.02
        // VS Code Dark+ comment color: #6A9955
        let isComment = abs(r - 0x6A/255.0) < 0.02 && abs(g - 0x99/255.0) < 0.02 && abs(b - 0x55/255.0) < 0.02
        return isString || isComment
    }

    /// Apply a color to regex matches, skipping strings/comments
    private static func applyPattern(_ pattern: NSRegularExpression, to textStorage: NSMutableAttributedString, color: NSColor, group: Int = 0) {
        let string = textStorage.string
        let fullRange = NSRange(location: 0, length: (string as NSString).length)
        let matches = pattern.matches(in: string, range: fullRange)
        for match in matches {
            let range = match.range(at: group)
            if range.location != NSNotFound && !isStringOrComment(textStorage, at: range.location) {
                textStorage.addAttribute(.foregroundColor, value: color, range: range)
            }
        }
    }

    /// Post-process highlighting for Python to add VS Code-like token coloring
    private static func postProcessPython(_ textStorage: NSMutableAttributedString) {
        // Constants (True/False/None) → blue (remap turned them purple with keywords)
        applyPattern(constantsPattern, to: textStorage, color: vsBlue)
        // `self` → light blue (variable)
        applyPattern(selfPattern, to: textStorage, color: vsLightBlue)
        // Built-in type names → teal
        applyPattern(builtinTypePattern, to: textStorage, color: vsTeal)
        // Type hints after `:` → teal
        applyPattern(typeHintPattern, to: textStorage, color: vsTeal, group: 1)
        // Return type annotations → teal
        applyPattern(returnTypePattern, to: textStorage, color: vsTeal, group: 1)
        // Function names after `def` → yellow
        applyPattern(funcDefPattern, to: textStorage, color: vsYellow, group: 1)
        // Class names after `class` → teal
        applyPattern(classNamePattern, to: textStorage, color: vsTeal, group: 1)
        // Superclass names in parens → teal
        applyPatternSplittingCommas(superclassPattern, to: textStorage, color: vsTeal)
        // Method calls → yellow (e.g., `.filter(`, `.first()`)
        applyPattern(methodCallPattern, to: textStorage, color: vsYellow, group: 1)
        // Dotted class references → teal (e.g., `fields.IntField`)
        applyPattern(dottedClassPattern, to: textStorage, color: vsTeal, group: 1)
        // Class-level variable assignments → light blue
        applyClassVarAssignments(textStorage)
    }

    /// Apply color to comma-separated superclass names (e.g., `class Foo(Base, Mixin)`)
    private static func applyPatternSplittingCommas(_ pattern: NSRegularExpression, to textStorage: NSMutableAttributedString, color: NSColor) {
        let string = textStorage.string
        let fullRange = NSRange(location: 0, length: (string as NSString).length)
        let matches = pattern.matches(in: string, range: fullRange)
        let identPattern = try! NSRegularExpression(pattern: "\\b([A-Za-z_]\\w*)\\b")
        for match in matches {
            let range = match.range(at: 1)
            if range.location == NSNotFound || isStringOrComment(textStorage, at: range.location) { continue }
            let substring = (string as NSString).substring(with: range)
            let subMatches = identPattern.matches(in: substring, range: NSRange(location: 0, length: (substring as NSString).length))
            for sub in subMatches {
                let subRange = sub.range(at: 1)
                let absRange = NSRange(location: range.location + subRange.location, length: subRange.length)
                textStorage.addAttribute(.foregroundColor, value: color, range: absRange)
            }
        }
    }

    /// Color class-level variable assignments (indented names before = or :, but not `def`, `class`, `return`, etc.)
    private static func applyClassVarAssignments(_ textStorage: NSMutableAttributedString) {
        let string = textStorage.string
        let fullRange = NSRange(location: 0, length: (string as NSString).length)
        let matches = varAssignPattern.matches(in: string, range: fullRange)
        let keywords: Set<String> = ["def", "class", "return", "if", "elif", "else", "for", "while", "try", "except",
                                      "finally", "with", "as", "import", "from", "raise", "pass", "break", "continue",
                                      "yield", "assert", "del", "global", "nonlocal", "async", "await", "self"]
        for match in matches {
            let nameRange = match.range(at: 2)
            if nameRange.location == NSNotFound { continue }
            let name = (string as NSString).substring(with: nameRange)
            if keywords.contains(name) { continue }
            if isStringOrComment(textStorage, at: nameRange.location) { continue }
            textStorage.addAttribute(.foregroundColor, value: vsLightBlue, range: nameRange)
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
        remapColors(textStorage)
        if language == "python" {
            postProcessPython(textStorage)
        }
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
        remapColors(mutable)
        if language == "python" {
            postProcessPython(mutable)
        }

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
