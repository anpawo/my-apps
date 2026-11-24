import SwiftUI

struct RoadmapGroupCard: View {
    var group: RoadmapGroup
    var active: Set<String>
    var accent: Color
    @State private var expanded: Bool?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var activeCount: Int { group.steps.filter { active.contains($0.id) }.count }
    private var isExpanded: Bool { expanded ?? (activeCount > 0) }
    private static let expansionDuration: TimeInterval = 0.25
    private static let reducedDuration: TimeInterval = 0.2
    private static let backgroundOpacity = 0.96
    private var animation: Animation { .easeOut(duration: reduceMotion ? Self.reducedDuration : Self.expansionDuration) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(animation) { expanded = !isExpanded }
            } label: { header }
                .buttonStyle(.plain)
                .accessibilityHint(isExpanded ? "Collapse grouped steps" : "Expand grouped steps")
            if isExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(group.steps) { step in
                        RoadmapStepCard(step: step, active: active.contains(step.id), accent: accent)
                    }
                }
                .transition(.opacity)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 11).fill(Color(red: 0.07, green: 0.08, blue: 0.11).opacity(Self.backgroundOpacity)))
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(activeCount > 0 ? accent : .white.opacity(0.3), lineWidth: activeCount > 0 ? 1.5 : 1))
        .clipped()
        .animation(animation, value: activeCount)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                if group.isDone {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(accent).accessibilityLabel("All recorded items done")
                }
                if activeCount > 0 {
                    Circle().fill(accent).frame(width: 7, height: 7).accessibilityLabel("Live work")
                }
                Text(group.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
            }
            HStack {
                Text("\(group.doneCount)/\(group.steps.count) done")
                Spacer(minLength: 0)
                if activeCount > 0 { Text("\(activeCount) working").foregroundStyle(accent) }
            }
            .font(.system(size: 12)).foregroundStyle(.white.opacity(0.85))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}
