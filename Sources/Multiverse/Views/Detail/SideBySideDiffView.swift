import SwiftUI
import AppKit

// MARK: - Synced scroll container (AppKit)

private class SyncedScrollContainer: NSView {
    let leftScrollView = NSScrollView()
    let rightScrollView = NSScrollView()
    let dividerLine = NSView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupScrollViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func setupScrollViews() {
        leftScrollView.hasVerticalScroller = true
        leftScrollView.hasHorizontalScroller = true
        leftScrollView.autohidesScrollers = true
        leftScrollView.drawsBackground = false

        rightScrollView.hasVerticalScroller = false
        rightScrollView.hasHorizontalScroller = true
        rightScrollView.autohidesScrollers = true
        rightScrollView.drawsBackground = false

        dividerLine.wantsLayer = true
        dividerLine.layer?.backgroundColor = NSColor.gray.withAlphaComponent(0.3).cgColor

        addSubview(leftScrollView)
        addSubview(dividerLine)
        addSubview(rightScrollView)
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        layoutPanes()
    }

    func layoutPanes() {
        let halfWidth = floor(bounds.width / 2)
        let height = bounds.height

        leftScrollView.frame = CGRect(x: 0, y: 0, width: halfWidth, height: height)
        dividerLine.frame = CGRect(x: halfWidth, y: 0, width: 1, height: height)
        rightScrollView.frame = CGRect(x: halfWidth + 1, y: 0,
                                       width: bounds.width - halfWidth - 1, height: height)

        updateDocumentSizes()
    }

    func updateDocumentSizes() {
        for scrollView in [leftScrollView, rightScrollView] {
            guard let docView = scrollView.documentView else { continue }
            let fitSize = docView.fittingSize
            let paneWidth = scrollView.bounds.width
            docView.frame.size = CGSize(
                width: max(fitSize.width, paneWidth),
                height: max(fitSize.height, scrollView.bounds.height)
            )
        }
    }
}

// MARK: - NSViewRepresentable with scroll sync

private struct SyncedDiffScrollView<Left: View, Right: View>: NSViewRepresentable {
    let leftContent: Left
    let rightContent: Right

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> SyncedScrollContainer {
        let container = SyncedScrollContainer(frame: .zero)

        let leftHosting = NSHostingView(rootView: leftContent)
        leftHosting.translatesAutoresizingMaskIntoConstraints = true
        container.leftScrollView.documentView = leftHosting

        let rightHosting = NSHostingView(rootView: rightContent)
        rightHosting.translatesAutoresizingMaskIntoConstraints = true
        container.rightScrollView.documentView = rightHosting

        context.coordinator.startSyncing(container: container)
        return container
    }

    func updateNSView(_ container: SyncedScrollContainer, context: Context) {
        if let leftHosting = container.leftScrollView.documentView as? NSHostingView<Left> {
            leftHosting.rootView = leftContent
        }
        if let rightHosting = container.rightScrollView.documentView as? NSHostingView<Right> {
            rightHosting.rootView = rightContent
        }

        DispatchQueue.main.async {
            container.updateDocumentSizes()
        }
    }

    // MARK: Coordinator — scroll synchronization

    @MainActor
    class Coordinator: NSObject {
        private weak var container: SyncedScrollContainer?
        private var isSyncing = false

        func startSyncing(container: SyncedScrollContainer) {
            self.container = container

            let leftClip = container.leftScrollView.contentView
            let rightClip = container.rightScrollView.contentView

            leftClip.postsBoundsChangedNotifications = true
            rightClip.postsBoundsChangedNotifications = true

            NotificationCenter.default.addObserver(
                self, selector: #selector(leftDidScroll),
                name: NSView.boundsDidChangeNotification,
                object: leftClip
            )
            NotificationCenter.default.addObserver(
                self, selector: #selector(rightDidScroll),
                name: NSView.boundsDidChangeNotification,
                object: rightClip
            )
        }

        @objc private func leftDidScroll(_ note: Notification) {
            guard !isSyncing, let c = container else { return }
            isSyncing = true
            let origin = c.leftScrollView.contentView.bounds.origin
            c.rightScrollView.contentView.scroll(to: origin)
            c.rightScrollView.reflectScrolledClipView(c.rightScrollView.contentView)
            isSyncing = false
        }

        @objc private func rightDidScroll(_ note: Notification) {
            guard !isSyncing, let c = container else { return }
            isSyncing = true
            let origin = c.rightScrollView.contentView.bounds.origin
            c.leftScrollView.contentView.scroll(to: origin)
            c.leftScrollView.reflectScrolledClipView(c.leftScrollView.contentView)
            isSyncing = false
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }
    }
}

// MARK: - SwiftUI view

struct SideBySideDiffView: View {
    let lines: [SideBySideLine]
    let filename: String

    private let rowHeight: CGFloat = 22

    var body: some View {
        if lines.isEmpty {
            ContentUnavailableView(
                "No Diff Selected",
                systemImage: "doc.text",
                description: Text("Double-click a file to view side-by-side diff.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                // Header
                HStack {
                    Image(systemName: "arrow.left.arrow.right")
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
                    let halfWidth = geo.size.width / 2

                    SyncedDiffScrollView(
                        leftContent: paneColumn(
                            lines: lines.map(\.left),
                            minWidth: halfWidth
                        ),
                        rightContent: paneColumn(
                            lines: lines.map(\.right),
                            minWidth: halfWidth
                        )
                    )
                    .overlay(alignment: .leading) {
                        changeMarkerStrip(
                            height: geo.size.height,
                            lines: lines.map(\.left),
                            colors: [.removed: .red, .modified: .orange]
                        )
                    }
                    .overlay(alignment: .trailing) {
                        changeMarkerStrip(
                            height: geo.size.height,
                            lines: lines.map(\.right),
                            colors: [.added: .green, .modified: .blue]
                        )
                    }
                }
            }
        }
    }

    // MARK: - Pane content

    private func paneColumn(lines: [SideLine], minWidth: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, side in
                sideLineView(side)
                    .frame(height: rowHeight)
            }
        }
        .frame(minWidth: minWidth, alignment: .leading)
    }

    @ViewBuilder
    private func sideLineView(_ side: SideLine) -> some View {
        HStack(spacing: 0) {
            if side.type == .spacer {
                Color.white.opacity(0.02)
                    .frame(width: 40)
            } else {
                // Line number
                Text(side.lineNumber.map(String.init) ?? "")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .frame(width: 36, alignment: .trailing)
                    .padding(.trailing, 4)

                // Content
                Text(side.content)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(backgroundColor(for: side.type))
    }

    private func backgroundColor(for type: SideLineType) -> Color {
        switch type {
        case .removed: .red.opacity(0.15)
        case .added: .green.opacity(0.15)
        case .modified: .yellow.opacity(0.1)
        case .spacer: .white.opacity(0.02)
        case .unchanged: .clear
        }
    }

    // MARK: - Scrollbar marker strip

    private func changeMarkerStrip(height: CGFloat, lines: [SideLine],
                                    colors: [SideLineType: Color]) -> some View {
        let total = CGFloat(self.lines.count)
        let regions = markerRegions(from: lines, colors: colors)

        return ZStack(alignment: .top) {
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

    private struct MarkerRegion {
        let startLine: Int
        let lineCount: Int
        let color: Color
    }

    private func markerRegions(from lines: [SideLine], colors: [SideLineType: Color]) -> [MarkerRegion] {
        var regions: [MarkerRegion] = []
        var i = 0
        while i < lines.count {
            let type = lines[i].type
            if let color = colors[type] {
                let start = i
                while i < lines.count && lines[i].type == type {
                    i += 1
                }
                regions.append(MarkerRegion(startLine: start, lineCount: i - start, color: color))
            } else {
                i += 1
            }
        }
        return regions
    }
}
