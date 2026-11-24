import SwiftUI

struct RoadmapDashboard: View {
    @ObservedObject var store: RoadmapStore
    var sessions: [Session]
    var back: () -> Void
    private static let pageInset: CGFloat = 32
    private static let gap: CGFloat = 16

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .firstTextBaseline) {
                Button(action: back) { Label("Fleet", systemImage: "chevron.left") }
                    .buttonStyle(.plain)
                    .help("Return to Fleet, or swipe right")
                Spacer()
                Text("ROADMAPS").font(.system(size: 13, weight: .bold, design: .monospaced)).tracking(3)
                Spacer()
                Text("Swipe right to return").font(.system(size: 12)).foregroundStyle(.white.opacity(0.85))
            }
            HStack(alignment: .top, spacing: Self.gap) {
                ForEach(store.snapshots, id: \.project.id) { snapshot in
                    RoadmapColumn(snapshot: snapshot, sessions: sessions)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            Text("Dots show live work. Ticks show source-confirmed completion. Expand a group to see its individual steps.")
                .font(.system(size: 12)).foregroundStyle(.white.opacity(0.85))
        }
        .foregroundStyle(.white)
        .padding(Self.pageInset)
        .padding(.top, OverlayView.menuBar)
    }
}

struct RoadmapColumn: View {
    var snapshot: RoadmapSnapshot
    var sessions: [Session]
    private var working: [Session] { snapshot.project.working(sessions) }
    private var active: Set<String> { working.reduce(into: Set<String>()) { $0.formUnion(RoadmapActivity.steps(for: $1, in: snapshot.steps)) } }
    private var unmatched: Int { working.filter { RoadmapActivity.steps(for: $0, in: snapshot.steps).isEmpty }.count }
    private var groups: [RoadmapGroup] { RoadmapGrouping.groups(snapshot) }
    private var accent: Color {
        switch snapshot.project.name {
        case "Recon": return Color(red: 0.45, green: 0.90, blue: 0.85)
        case "Stele": return Color(red: 0.78, green: 0.68, blue: 1)
        case "CER": return Color(red: 1, green: 0.78, blue: 0.40)
        default: return Color(red: 1, green: 0.62, blue: 0.82)
        }
    }
    private static let backgroundDarkening = 0.68
    private static let backgroundOpacity = 0.94

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider().overlay(accent.opacity(0.4))
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 12) {
                    evidence
                    ForEach(groups) { group in
                        if group.steps.count == 1, let step = group.steps.first {
                            RoadmapStepCard(step: step, active: active.contains(step.id), accent: accent)
                        } else {
                            RoadmapGroupCard(group: group, active: active, accent: accent)
                        }
                    }
                    if snapshot.loaded && snapshot.steps.isEmpty {
                        Text("No roadmap steps available")
                            .font(.system(size: 13)).foregroundStyle(.white.opacity(0.85))
                            .frame(maxWidth: .infinity, minHeight: 100)
                    }
                }
                .padding(2)
            }
            .scrollIndicators(.visible)
            .scrollBounceBehavior(.basedOnSize)
            .accessibilityLabel(snapshot.project.name + " roadmap steps")
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 18).fill(accent.darkened(Self.backgroundDarkening).opacity(Self.backgroundOpacity)))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(accent.opacity(0.65)))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(snapshot.project.name).font(.system(size: 23, weight: .semibold)).foregroundStyle(accent)
            HStack(spacing: 6) {
                Circle().fill(working.isEmpty ? .white.opacity(0.25) : accent).frame(width: 6, height: 6)
                Text("\(working.count) working \(working.count == 1 ? "agent" : "agents")")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
            }
            .help("Fleet sessions marked WORKING or BACKGROUND-TASK, assigned to this project")
            if unmatched > 0 {
                Text("\(unmatched) without a matched step").font(.system(size: 12)).foregroundStyle(.white.opacity(0.85))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var evidence: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(snapshot.notices, id: \.self) { notice in
                Text(notice).foregroundStyle(Color(red: 1, green: 0.85, blue: 0.55))
            }
            if let date = snapshot.updated {
                Text("Source updated " + date.formatted(date: .abbreviated, time: .omitted))
                    .foregroundStyle(.white.opacity(0.85))
                if snapshot.stale { Text("Older than 14 days; status may be stale").foregroundStyle(Color(red: 1, green: 0.85, blue: 0.55)) }
            }
            Text(snapshot.loaded ? "\(groups.count) groups · \(snapshot.steps.count) items · \(snapshot.steps.filter(\.isDone).count) done" : "Loading local sources…")
                .foregroundStyle(.white.opacity(0.85))
        }
        .font(.system(size: 12))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct RoadmapStepCard: View {
    var step: RoadmapStep
    var active: Bool
    var accent: Color
    @State private var expanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static let expansionDuration: TimeInterval = 0.25
    private static let reducedDuration: TimeInterval = 0.2
    private static let backgroundOpacity = 0.96
    private static let activeBackgroundDarkening = 0.78

    var body: some View {
        Button {
            withAnimation(.easeOut(duration: reduceMotion ? Self.reducedDuration : Self.expansionDuration)) { expanded.toggle() }
        } label: {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 7) {
                    if step.isDone {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(accent).accessibilityLabel("Done (source)")
                    }
                    if active { Circle().fill(accent).frame(width: 7, height: 7).accessibilityLabel("Live work") }
                    Text(step.id.hasPrefix("S") && !step.id.contains("/") ? step.id : "STEP")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                    Spacer(minLength: 0)
                    if active { Text("WORKING").font(.system(size: 10, weight: .bold)) }
                }
                .foregroundStyle(active ? accent : .white.opacity(0.85))
                Text(step.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white).fixedSize(horizontal: false, vertical: true)
                Text(step.status).font(.system(size: 12)).foregroundStyle(.white.opacity(0.85))
                if expanded {
                    VStack(alignment: .leading, spacing: 8) {
                        if !step.detail.isEmpty { Text(step.detail).font(.system(size: 13)).foregroundStyle(.white.opacity(0.9)) }
                        Text(step.source.lastPathComponent).font(.system(size: 11, design: .monospaced)).foregroundStyle(.white.opacity(0.85))
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 11).fill((active ? accent.darkened(Self.activeBackgroundDarkening) : Color(red: 0.07, green: 0.08, blue: 0.11)).opacity(Self.backgroundOpacity)))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(active ? accent : .white.opacity(0.3), lineWidth: active ? 1.5 : 1))
            .clipped()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(step.title + ", " + step.status + (step.isDone ? ", done" : "") + (active ? ", live work" : ""))
        .accessibilityHint(expanded ? "Collapse step details" : "Expand step details")
    }
}
