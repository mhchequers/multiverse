import SwiftUI

struct DiffView: View {
    let lines: [DiffLine]
    let filename: String

    var body: some View {
        if lines.isEmpty {
            ContentUnavailableView(
                "No Diff Selected",
                systemImage: "doc.text",
                description: Text("Select a file to view its diff.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Image(systemName: "doc.text")
                    Text(filename)
                        .fontWeight(.medium)
                    Spacer()
                }
                .font(.callout)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.white.opacity(0.05))

                Divider()

                GeometryReader { geo in
                    ScrollView([.horizontal, .vertical]) {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                                HStack(spacing: 0) {
                                    // Line number
                                    Text("\(index + 1)")
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundStyle(.tertiary)
                                        .frame(width: 44, alignment: .trailing)
                                        .padding(.trailing, 4)

                                    // Gutter bar
                                    Rectangle()
                                        .fill(gutterColor(for: line.type))
                                        .frame(width: 3)
                                        .padding(.trailing, 8)

                                    // File content
                                    Text(line.highlightedContent ?? AttributedString(line.content))
                                        .font(.system(.body, design: .monospaced))
                                        .lineLimit(1)
                                        .fixedSize(horizontal: true, vertical: false)
                                }
                                .padding(.vertical, 1)
                            }
                        }
                        .frame(minWidth: geo.size.width, alignment: .leading)
                        .padding(.vertical, 4)
                    }
                    .overlay(alignment: .trailing) {
                        changeMarkerStrip(height: geo.size.height)
                    }
                }
            }
        }
    }

    private func changeMarkerStrip(height: CGFloat) -> some View {
        let regions = changeRegions()
        let total = CGFloat(lines.count)

        return ZStack(alignment: .top) {
            // Subtle track background
            Rectangle()
                .fill(.white.opacity(0.03))

            ForEach(Array(regions.enumerated()), id: \.offset) { _, region in
                let y = (CGFloat(region.startLine) / total) * height
                let h = max(2, (CGFloat(region.lineCount) / total) * height)

                Rectangle()
                    .fill(region.color.opacity(0.8))
                    .frame(height: h)
                    .offset(y: y)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .frame(width: 10)
        .allowsHitTesting(false)
    }

    private struct ChangeRegion {
        let startLine: Int
        let lineCount: Int
        let color: Color
    }

    private func changeRegions() -> [ChangeRegion] {
        var regions: [ChangeRegion] = []
        var i = 0
        while i < lines.count {
            let type = lines[i].type
            if type != .unchanged {
                let start = i
                let color = gutterColor(for: type)
                while i < lines.count && lines[i].type == type {
                    i += 1
                }
                regions.append(ChangeRegion(startLine: start, lineCount: i - start, color: color))
            } else {
                i += 1
            }
        }
        return regions
    }

    private func gutterColor(for type: DiffLine.LineType) -> Color {
        switch type {
        case .added: .green
        case .modified: .blue
        case .unchanged: .clear
        }
    }
}
