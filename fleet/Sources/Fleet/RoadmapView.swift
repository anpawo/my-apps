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
                Text("Swipe right to return").font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
            }
            HStack(alignment: .top, spacing: Self.gap) {
                ForEach(store.snapshots, id: \.project.id) { snapshot in
                    RoadmapColumn(snapshot: snapshot, sessions: sessions)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            Text("Dots show live work matched to a step. Source status is separate from agent activity.")
                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
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
    private let accent = Color(red: 0.70, green: 0.60, blue: 1)
    private static let backgroundDarkening = 0.48

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider().overlay(.white.opacity(0.08))
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 12) {
                    evidence
                    ForEach(snapshot.steps) { step in
                        RoadmapStepCard(step: step, active: active.contains(step.id), accent: accent)
                    }
                    if snapshot.loaded && snapshot.steps.isEmpty {
                        Text("No roadmap steps available")
                            .font(.system(size: 13)).foregroundStyle(.white.opacity(0.55))
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
        .background(RoundedRectangle(cornerRadius: 18).fill(accent.darkened(Self.backgroundDarkening).opacity(Glass.wash)))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.12)))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(snapshot.project.name).font(.system(size: 23, weight: .semibold))
            HStack(spacing: 6) {
                Circle().fill(working.isEmpty ? .white.opacity(0.25) : accent).frame(width: 6, height: 6)
                Text("\(working.count) working \(working.count == 1 ? "agent" : "agents")")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
            }
            .help("Fleet sessions marked WORKING or BACKGROUND-TASK, assigned to this project")
            if unmatched > 0 {
                Text("\(unmatched) without a matched step").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var evidence: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(snapshot.notices, id: \.self) { notice in
                Text(notice).foregroundStyle(.orange.opacity(0.9))
            }
            if let date = snapshot.updated {
                Text("Source updated " + date.formatted(date: .abbreviated, time: .omitted))
                    .foregroundStyle(.white.opacity(0.4))
                if snapshot.stale { Text("Older than 14 days; status may be stale").foregroundStyle(.orange) }
            }
            Text(snapshot.loaded ? "\(snapshot.steps.count) steps" : "Loading local sources…")
                .foregroundStyle(.white.opacity(0.4))
        }
        .font(.system(size: 11))
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

    var body: some View {
        Button {
            withAnimation(.easeOut(duration: reduceMotion ? Self.reducedDuration : Self.expansionDuration)) { expanded.toggle() }
        } label: {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 7) {
                    if active { Circle().fill(accent).frame(width: 7, height: 7).accessibilityLabel("Live work") }
                    Text(step.id.hasPrefix("S") && !step.id.contains("/") ? step.id : "STEP")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                    Spacer(minLength: 0)
                    if active { Text("WORKING").font(.system(size: 9, weight: .bold)) }
                }
                .foregroundStyle(active ? accent : .white.opacity(0.4))
                Text(step.title).font(.system(size: 14, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                Text(step.status).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                if expanded {
                    VStack(alignment: .leading, spacing: 8) {
                        if !step.detail.isEmpty { Text(step.detail).font(.system(size: 12)).foregroundStyle(.white.opacity(0.7)) }
                        Text(step.source.lastPathComponent).font(.system(size: 10, design: .monospaced)).foregroundStyle(.white.opacity(0.35))
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 11).fill(active ? accent.opacity(0.10) : .black.opacity(0.12)))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(active ? accent.opacity(0.85) : .white.opacity(0.08), lineWidth: active ? 1.5 : 1))
            .clipped()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(step.title + ", " + step.status + (active ? ", live work" : ""))
        .accessibilityHint(expanded ? "Collapse step details" : "Expand step details")
    }
}
