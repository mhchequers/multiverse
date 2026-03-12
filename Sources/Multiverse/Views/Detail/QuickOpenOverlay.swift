import SwiftUI

struct QuickOpenOverlay: View {
    let vm: FileExplorerViewModel
    @FocusState private var isSearchFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Search bar
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 14))

                TextField("Go to File...", text: Binding(
                    get: { vm.quickOpenQuery },
                    set: { vm.quickOpenQuery = $0 }
                ))
                .textFieldStyle(.plain)
                .font(.system(size: 14, design: .monospaced))
                .focused($isSearchFieldFocused)
                .onSubmit {
                    vm.quickOpenConfirmSelection()
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            // Results list
            let results = vm.quickOpenResults

            if results.isEmpty {
                Text(vm.quickOpenQuery.isEmpty ? "No recent files" : "No matching files")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 13))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(results.enumerated()), id: \.element.filePath) { index, result in
                                QuickOpenResultRow(
                                    result: result,
                                    isSelected: index == vm.quickOpenSelectedIndex
                                )
                                .id(result.filePath)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    vm.quickOpenSelectedIndex = index
                                    vm.quickOpenConfirmSelection()
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 400)
                    .onChange(of: vm.quickOpenSelectedIndex) { _, newIndex in
                        if newIndex >= 0, newIndex < results.count {
                            proxy.scrollTo(results[newIndex].filePath, anchor: .center)
                        }
                    }
                }
            }
        }
        .frame(width: 500)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(0.5), radius: 20, y: 10)
        .onAppear { isSearchFieldFocused = true }
        .onChange(of: vm.quickOpenQuery) { _, _ in
            vm.quickOpenSelectedIndex = 0
        }
        .onKeyPress(.upArrow) {
            vm.quickOpenMoveSelection(by: -1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            vm.quickOpenMoveSelection(by: 1)
            return .handled
        }
        .onKeyPress(.escape) {
            vm.dismissQuickOpen()
            return .handled
        }
    }
}

private struct QuickOpenResultRow: View {
    let result: QuickOpenResult
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: fileIcon(for: result.filename))
                .foregroundStyle(.secondary)
                .font(.system(size: 12))
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                highlightedFilename
                    .font(.system(size: 13, design: .monospaced))

                if !result.directory.isEmpty {
                    Text(result.directory)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(isSelected ? Color.accentColor.opacity(0.3) : Color.clear)
    }

    private var highlightedFilename: Text {
        let matchedSet = Set(result.matchedIndices)
        // Find where the filename starts in the full path
        let filenameStart = result.filePath.count - result.filename.count

        var text = Text("")
        for (i, char) in result.filename.enumerated() {
            let globalIndex = filenameStart + i
            if matchedSet.contains(globalIndex) {
                text = text + Text(String(char))
                    .foregroundColor(.primary)
                    .bold()
            } else {
                text = text + Text(String(char))
                    .foregroundColor(.secondary)
            }
        }
        return text
    }
}

private func fileIcon(for name: String) -> String {
    let ext = (name as NSString).pathExtension.lowercased()
    switch ext {
    case "swift": return "swift"
    case "js", "ts", "jsx", "tsx": return "curlybraces"
    case "json": return "curlybraces.square"
    case "md", "txt": return "doc.text"
    case "yml", "yaml", "toml": return "gearshape"
    case "py": return "chevron.left.forwardslash.chevron.right"
    case "html", "css": return "globe"
    case "png", "jpg", "jpeg", "gif", "svg": return "photo"
    default: return "doc"
    }
}
