import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class ShelfModule: NotchModule {
    let id = "shelf"
    let title = "Shelf"
    let symbol = "tray.full"
    func expandedView() -> AnyView { AnyView(ShelfView()) }
    func start() { ShelfService.shared.start() }
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
                NotchScroll(axis: .horizontal) {
                    HStack(spacing: 10) {
                        ForEach(shelf.items) { ShelfTile(item: $0) }
                    }
                    .padding(.vertical, 2)
                }
                Text("Drag a file out to use it. Option-click removes it.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiaryInk)
            }
        }
    }
}

private struct ShelfTile: View {
    let item: ShelfItem
    @State private var hovering = false
    private var shelf: ShelfService { .shared }

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .topTrailing) {
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

                if hovering {
                    Button { shelf.remove(item) } label: { Image(systemName: "xmark") }
                        .buttonStyle(IconButtonStyle(size: 20))
                        .offset(x: 6, y: -6)
                        .help("Remove from shelf")
                }
            }
            Text(item.name)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(width: 92, height: 28, alignment: .top)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 12).fill(hovering ? Theme.fill : .clear))
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onHover { hovering = $0 }
        .onAppear { shelf.loadThumbnail(for: item) }
        .onDrag {
            guard let url = shelf.url(for: item) else { return NSItemProvider() }
            return NSItemProvider(contentsOf: url) ?? NSItemProvider()
        }
        .simultaneousGesture(TapGesture(count: 2).onEnded { shelf.open(item) })
        .simultaneousGesture(TapGesture().modifiers(.option).onEnded { shelf.remove(item) })
        .contextMenu {
            Button("Open") { shelf.open(item) }
            Button("Show in Finder") { shelf.reveal(item) }
            if shelf.canAirDrop {
                Button("AirDrop…") { shelf.airDrop([item]) }
            }
            Divider()
            Button("Remove from Shelf") { shelf.remove(item) }
        }
        .help(item.name)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Drag to use the file. Double-click to open.")
    }
}
