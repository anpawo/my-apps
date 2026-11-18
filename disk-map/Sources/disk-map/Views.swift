import AppKit
import SwiftUI

struct Browser: View {
    @ObservedObject var model: Model
    @State private var doomed: Item?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let columns = [GridItem(.adaptive(minimum: 112, maximum: 132), spacing: 8)]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(model.items) { item in
                        Tile(item: item).onTapGesture { go { model.open(item) } }
                            .contextMenu { menu(item) }
                    }
                }
                .padding(16)
                .id(model.path)
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.97)))
            }
        }
        .frame(minWidth: 560, minHeight: 380)
        .confirmationDialog("Delete \(doomed?.name ?? "")?", isPresented: .init(get: { doomed != nil }, set: { if !$0 { doomed = nil } })) {
            if let item = doomed {
                Button("Move to Trash") { model.remove(item, permanently: false) }
                Button("Delete Permanently", role: .destructive) { model.remove(item, permanently: true) }
            }
        } message: {
            Text("\(doomed?.id ?? "")\n\(gigabytes(doomed?.size))")
        }
        .alert("Could not delete", isPresented: .init(get: { model.problem != nil }, set: { if !$0 { model.problem = nil } })) {
        } message: { Text(model.problem ?? "") }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button { go { model.up() } } label: { Image(systemName: "chevron.left") }
                .keyboardShortcut(.upArrow, modifiers: .command)
                .disabled(model.path == "/")
            Text(model.path).font(.headline).lineLimit(1).truncationMode(.head)
            Spacer()
            if model.scanning {
                ProgressView().controlSize(.small)
                Text("Scanning, \(model.files.formatted()) files").foregroundStyle(.secondary).monospacedDigit()
            }
            Text(gigabytes(model.total)).font(.headline).monospacedDigit()
            Button { model.scan() } label: { Image(systemName: "arrow.clockwise") }
                .disabled(model.scanning).help("Scan again")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    @ViewBuilder private func menu(_ item: Item) -> some View {
        Button("Open") { go { model.open(item) } }
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.id)]) }
        Divider()
        Button("Delete…", role: .destructive) { doomed = item }
    }

    private func go(_ change: () -> Void) {
        withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(duration: 0.28)) { change() }
    }
}

struct Tile: View {
    let item: Item
    @State private var hover = false

    var body: some View {
        VStack(spacing: 4) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.id))
                .resizable().frame(width: 64, height: 64)
            Text(item.name)
                .font(.system(size: 12)).lineLimit(2).multilineTextAlignment(.center).truncationMode(.middle)
            Text(item.unscanned ? "not scanned" : gigabytes(item.size))
                .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
        }
        .frame(width: 112, height: 116, alignment: .top)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(hover ? Color.primary.opacity(0.08) : .clear))
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
    }
}
