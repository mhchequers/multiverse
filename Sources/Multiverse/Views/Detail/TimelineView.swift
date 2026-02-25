import SwiftUI

struct TimelineView: View {
    let project: Project

    private var sortedActivities: [ProjectActivity] {
        project.activities.sorted { $0.timestamp > $1.timestamp }
    }

    private var groupedActivities: [(String, [ProjectActivity])] {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none

        var groups: [(String, [ProjectActivity])] = []
        var currentLabel = ""
        var currentGroup: [ProjectActivity] = []

        for activity in sortedActivities {
            let label: String
            if calendar.isDateInToday(activity.timestamp) {
                label = "Today"
            } else if calendar.isDateInYesterday(activity.timestamp) {
                label = "Yesterday"
            } else {
                label = formatter.string(from: activity.timestamp)
            }

            if label != currentLabel {
                if !currentGroup.isEmpty {
                    groups.append((currentLabel, currentGroup))
                }
                currentLabel = label
                currentGroup = [activity]
            } else {
                currentGroup.append(activity)
            }
        }
        if !currentGroup.isEmpty {
            groups.append((currentLabel, currentGroup))
        }
        return groups
    }

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        if sortedActivities.isEmpty {
            ContentUnavailableView(
                "No Activity",
                systemImage: "clock",
                description: Text("Events will appear here as you work on this project.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            SwiftUI.TimelineView(.periodic(from: .now, by: 60)) { context in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(groupedActivities.enumerated()), id: \.offset) { groupIndex, group in
                            let (label, activities) = group

                            // Section header
                            Text(label)
                                .font(.caption)
                                .fontWeight(.bold)
                                .foregroundStyle(.secondary)
                                .padding(.leading, 16)
                                .padding(.top, groupIndex == 0 ? 12 : 20)
                                .padding(.bottom, 6)

                            // Events in this group
                            ForEach(Array(activities.enumerated()), id: \.element.id) { index, activity in
                                let isLast = groupIndex == groupedActivities.count - 1 && index == activities.count - 1

                                HStack(alignment: .top, spacing: 10) {
                                    // Timeline dot + connecting line
                                    ZStack(alignment: .top) {
                                        // Connecting line below the dot
                                        if !isLast {
                                            Rectangle()
                                                .fill(Color.gray.opacity(0.3))
                                                .frame(width: 1)
                                                .padding(.top, 12)
                                        }

                                        // Colored dot
                                        Circle()
                                            .fill(activity.eventType.color)
                                            .frame(width: 8, height: 8)
                                            .padding(.top, 4)
                                    }
                                    .frame(width: 8)

                                    // Event content
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(alignment: .firstTextBaseline) {
                                            Text(activity.eventType.label)
                                                .font(.body)

                                            Spacer()

                                            QuickTooltipTimestamp(
                                                date: activity.timestamp,
                                                now: context.date,
                                                formatter: Self.timestampFormatter
                                            )
                                        }

                                        if let detail = activity.detail, !detail.isEmpty {
                                            Text(detail)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 4)
                            }
                        }
                    }
                    .padding(.bottom, 12)
                }
            }
        }
    }
}

private struct QuickTooltipTimestamp: View {
    let date: Date
    let now: Date
    let formatter: DateFormatter
    @State private var isHovered = false
    @State private var hoverWork: DispatchWorkItem?

    private static let relativeFormatter: DateComponentsFormatter = {
        let f = DateComponentsFormatter()
        f.maximumUnitCount = 1
        f.unitsStyle = .abbreviated
        f.allowedUnits = [.year, .month, .weekOfMonth, .day, .hour, .minute]
        return f
    }()

    private var relativeText: String {
        let interval = now.timeIntervalSince(date)
        if interval < 60 {
            return "just now"
        }
        if let str = Self.relativeFormatter.string(from: date, to: now) {
            return "\(str) ago"
        }
        return "just now"
    }

    var body: some View {
        Text(relativeText)
            .font(.caption)
            .foregroundStyle(.tertiary)
            .padding(.vertical, 2)
            .padding(.horizontal, 4)
            .overlay(alignment: .topTrailing) {
                if isHovered {
                    Text(formatter.string(from: date))
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.ultraThinMaterial)
                        .cornerRadius(4)
                        .fixedSize()
                        .offset(y: -22)
                }
            }
            .zIndex(isHovered ? 1 : 0)
            .onHover { hovering in
                hoverWork?.cancel()
                if hovering {
                    let work = DispatchWorkItem {
                        withAnimation(.easeIn(duration: 0.15)) {
                            isHovered = true
                        }
                    }
                    hoverWork = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
                } else {
                    isHovered = false
                }
            }
    }
}
