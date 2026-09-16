import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class ShelfModule: NotchModule {
    let id = "shelf"
    let title = "Shelf"
    let symbol = "tray.full"
    func expandedView() -> AnyView { AnyView(ShelfView()) }
    func start() { ShelfService.shared.start() }
    func stop() { ShelfService.shared.stop() }
}

private struct ShelfView: View {
    private var shelf: ShelfService { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionLabel(shelf.items.isEmpty ? "Shelf" : "\(shelf.items.count) on the shelf")
                Spacer()
                if !shelf.items.isEmpty {
                    if shelf.canAirDrop {
                        Button { shelf.airDrop(shelf.items) } label: { Label("AirDrop all", systemImage: "square.and.arrow.up") }
                            .buttonStyle(PillButtonStyle(prominent: false))
                    }
                    Button("Clear") { shelf.removeAll() }
                        .buttonStyle(PillButtonStyle(prominent: false))
                }
            }

            if shelf.items.isEmpty {
                RoundedRectangle(cornerRadius: 18)
                    .strokeBorder(Theme.tertiaryInk, style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                    .overlay {
                        VStack(spacing: 6) {
                            Image(systemName: "tray.and.arrow.down.fill")
                                .font(.system(size: 26))
                                .foregroundStyle(Theme.secondaryInk)
                            Text("Drag files onto the notch")
                                .font(.system(size: 14, weight: .semibold))
                            Text("They wait here until you drag them somewhere else.")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.secondaryInk)
                        }
                    }
            } else {
                NotchScroll(axis: .horizontal, clipsContent: false) {
                    HStack(spacing: 10) {
                        ForEach(shelf.items) { ShelfTile(item: $0) }
                    }
                    .padding(.vertical, 2)
                }
                Text("Drag a file out to use it. Flick it up to remove it.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiaryInk)
            }
        }
        .onAppear { shelf.removeMissing() }
    }
}

private struct ShelfTile: View {
    let item: ShelfItem
    @State private var hovering = false
    @State private var flick = CGSize.zero
    @State private var thrown = false
    @Environment(\.snapshotMode) private var snapshotMode
    private var shelf: ShelfService { .shared }

    var body: some View {
        VStack(spacing: 6) {
            Group {
                if let image = shelf.thumbnails[item.id] {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: "doc").font(.system(size: 30)).foregroundStyle(Theme.secondaryInk)
                }
            }
            .frame(width: 76, height: 76)

            Text(item.name)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(width: 92, height: 28, alignment: .top)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 12).fill(hovering || flick != .zero ? Theme.fill : .clear))
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .overlay {
            if !snapshotMode {
                ShelfTileInteraction(item: item,
                                     onHover: { hovering = $0 },
                                     onFlick: { flick = $0 },
                                     onFlickEnded: flickEnded)
            }
        }
        .overlay(alignment: .topTrailing) {
            if hovering, flick == .zero {
                Button { shelf.remove(item) } label: { Image(systemName: "xmark") }
                    .buttonStyle(IconButtonStyle(size: 20))
                    .padding(2)
                    .help("Remove from shelf")
            }
        }
        .rotationEffect(.degrees(Double(flick.width) / 6))
        .offset(flick)
        .opacity(thrown ? 0 : 1 - 0.5 * min(1, Double(-flick.height) / 140))
        .onAppear { shelf.loadThumbnail(for: item) }
        .help(item.name)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Drag to use the file. Double-click to open. Flick up to remove.")
        .accessibilityAction(named: "Open") { shelf.open(item) }
        .accessibilityAction(named: "Show in Finder") { shelf.reveal(item) }
        .accessibilityAction(named: "Remove from Shelf") { shelf.remove(item) }
    }

    private func flickEnded(_ remove: Bool) {
        guard remove, !Motion.reduceMotion else {
            if remove {
                shelf.remove(item)
            } else {
                withAnimation(.spring(duration: 0.35, bounce: 0.45)) { flick = .zero }
            }
            return
        }
        Haptics.tick()
        withAnimation(.easeIn(duration: 0.2)) {
            flick = CGSize(width: flick.width * 1.6, height: -230)
            thrown = true
        }
        Task {
            try? await Task.sleep(for: .milliseconds(200))
            shelf.remove(item)
        }
    }
}
