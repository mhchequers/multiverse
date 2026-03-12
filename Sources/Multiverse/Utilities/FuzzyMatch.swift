import Foundation

struct QuickOpenResult {
    let filePath: String
    let filename: String
    let directory: String
    let matchedIndices: [Int]
    let score: Int
}

func fuzzyMatch(query: String, path: String) -> QuickOpenResult? {
    let queryChars = Array(query.lowercased())
    let pathLower = Array(path.lowercased())
    let pathOriginal = Array(path)

    guard !queryChars.isEmpty else { return nil }

    // Find filename start position
    let filenameStart: Int
    if let lastSlash = path.lastIndex(of: "/") {
        filenameStart = path.distance(from: path.startIndex, to: path.index(after: lastSlash))
    } else {
        filenameStart = 0
    }

    let filename = String(path[path.index(path.startIndex, offsetBy: filenameStart)...])
    let directory: String
    if filenameStart > 0 {
        directory = String(path[..<path.index(path.startIndex, offsetBy: filenameStart - 1)])
    } else {
        directory = ""
    }

    // Greedy left-to-right match
    var matchedIndices: [Int] = []
    var qi = 0
    for pi in 0..<pathLower.count {
        if qi < queryChars.count && pathLower[pi] == queryChars[qi] {
            matchedIndices.append(pi)
            qi += 1
        }
    }

    guard qi == queryChars.count else { return nil }

    // Scoring
    var score = 0

    for (mi, pathIndex) in matchedIndices.enumerated() {
        // Consecutive bonus
        if mi > 0 && matchedIndices[mi - 1] == pathIndex - 1 {
            score += 5
        }

        // Word boundary bonus
        if isBoundary(pathLower, at: pathIndex, original: pathOriginal) {
            score += 8
        }

        // Filename region bonus
        if pathIndex >= filenameStart {
            score += 3
        }
    }

    // Prefix bonus: first match is at start of filename
    if let first = matchedIndices.first, first == filenameStart {
        score += 10
    }

    // Path length penalty (shorter paths win ties)
    score -= pathLower.count

    return QuickOpenResult(
        filePath: path,
        filename: filename,
        directory: directory,
        matchedIndices: matchedIndices,
        score: score
    )
}

private func isBoundary(_ chars: [Character], at index: Int, original: [Character]) -> Bool {
    if index == 0 { return true }
    let prev = chars[index - 1]
    if prev == "/" || prev == "." || prev == "-" || prev == "_" { return true }
    // camelCase boundary
    if original[index].isUppercase && original[index - 1].isLowercase { return true }
    return false
}
