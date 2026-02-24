import Foundation

enum SlugGenerator {
    static func generate(from title: String) -> String {
        let slug = title
            .lowercased()
            .folding(options: .diacriticInsensitive, locale: .current)
            .replacingOccurrences(of: "[^a-z0-9\\s-]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))

        if slug.count <= 50 { return slug }
        let truncated = String(slug.prefix(50))
        if let lastDash = truncated.lastIndex(of: "-") {
            return String(truncated[truncated.startIndex..<lastDash])
        }
        return truncated
    }
}
