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
                if !shelf.items.isEmpty {
                    Text("Drag one out to use it, flick it up to remove it")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.tertiaryInk)
                        .padding(.leading, 8)
                }
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
                        // Where the next file goes.
                        RoundedRectangle(cornerRadius: 14)
                            .strokeBorder(Theme.tertiaryInk.opacity(0.7), style: StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
                            .overlay {
                                VStack(spacing: 5) {
                                    Image(systemName: "plus")
                                        .font(.system(size: 16, weight: .semibold))
                                    Text("Drop more\non the notch")
                                        .font(.system(size: 10, weight: .medium))
                                        .multilineTextAlignment(.center)
                                }
                                .foregroundStyle(Theme.tertiaryInk)
                            }
                            .frame(width: 108, height: 132)
                            .accessibilityHidden(true)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .onAppear { shelf.removeMissing() }
    }
}

private struct ShelfTile: View {
    let item: ShelfItem
    private var shelf: ShelfService { .shared }

    var body: some View {
        FileTile(name: item.name, handlers: shelf.tileHandlers(for: item)) {
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
                .frame(width: 92, height: 92)

                Text(item.name)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(width: 108, height: 28, alignment: .top)
            }
        }
        .onAppear { shelf.loadThumbnail(for: item) }
    }
}
