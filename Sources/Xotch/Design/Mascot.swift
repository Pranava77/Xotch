import AppKit
import ImageIO
import Observation
import SwiftUI

// A page mascot: a little character that turns its head toward the pointer
// and reacts when you boop it. The characters and the way they move come from
// page-mascot by Kamran Ahmed (MIT, github.com/nilbuild/page-mascot); the
// sheets are fetched and scaled down by scripts/fetch-mascots.sh.

/// One of the characters Xotch ships.
struct MascotCharacter: Identifiable, Hashable {
    let id: String

    var name: String { id == "crt" ? "CRT" : id.prefix(1).uppercased() + id.dropFirst() }

    static let all = ["fox", "cat", "bunny", "bear", "frog", "dino", "hamster", "deer",
                      "astronaut", "gearbot", "chef", "crt"].map(MascotCharacter.init)

    @MainActor static var chosen: MascotCharacter {
        all.first { $0.id == AppSettings.mascotCharacter } ?? all[0]
    }
}

/// How the mascot moves, taken from page-mascot's `mascot.tsx`.
enum MascotMotion {
    /// The directions sheet, row by row.
    enum Cell {
        static let upLeft = 0, up = 1, upRight = 2, left = 3, center = 4, right = 5
        static let downLeft = 6, down = 7, downRight = 8
    }

    /// The reactions sheet, row by row.
    enum Reaction {
        static let blink = 0, heart = 1, sparkle = 2, surprised = 3, wink = 4
        static let bashful = 5, sleepy = 6, dizzy = 7, delighted = 8
        /// What follows the blink on the first, second and third boop.
        static let payoffs = [heart, sparkle, delighted]
    }

    /// Closer than this, the mascot looks straight ahead.
    static let deadZone: CGFloat = 70
    /// How far past a sector's edge the pointer has to go before the head turns,
    /// so it doesn't flicker on the boundary.
    static let hysteresis: CGFloat = 0.12

    /// Sectors clockwise from the right, as the screen looks (y down).
    private static let sectors = [Cell.right, Cell.downRight, Cell.down, Cell.downLeft,
                                  Cell.left, Cell.upLeft, Cell.up, Cell.upRight]

    /// The directions cell to show for a pointer `dx`, `dy` points from the
    /// mascot in screen coordinates (y up), given the cell showing now.
    static func direction(dx: CGFloat, dy: CGFloat, previous: Int) -> Int {
        guard hypot(dx, dy) >= deadZone else { return Cell.center }
        let angle = atan2(-dy, dx)  // y down, like the page
        let width = CGFloat.pi / 4
        if let index = sectors.firstIndex(of: previous) {
            var offset = angle - CGFloat(index) * width
            while offset > .pi { offset -= 2 * .pi }
            while offset < -.pi { offset += 2 * .pi }
            if abs(offset) <= width / 2 + hysteresis { return previous }
        }
        var slot = Int((angle / width).rounded()) % 8
        if slot < 0 { slot += 8 }
        return sectors[slot]
    }
}

/// Counts boops: each one blinks, then shows a heart, a sparkle or delight in
/// turn; the fourth within 1.6 s makes the mascot dizzy instead.
struct BoopCounter {
    private var recent: [Date] = []

    /// The reaction a boop at `now` ends on.
    mutating func boop(at now: Date) -> Int {
        recent = recent.filter { now.timeIntervalSince($0) < 1.6 } + [now]
        if recent.count >= 4 {
            recent = []
            return MascotMotion.Reaction.dizzy
        }
        let payoffs = MascotMotion.Reaction.payoffs
        return payoffs[(recent.count - 1) % payoffs.count]
    }
}

/// The nine directions and nine reactions of the chosen character. Only one
/// character is kept in memory; choosing another frees the last.
@MainActor
final class MascotSprites {
    static let shared = MascotSprites()

    private var cached: (id: String, directions: [CGImage], reactions: [CGImage])?

    func cells(for character: MascotCharacter) -> (directions: [CGImage], reactions: [CGImage])? {
        if let cached, cached.id == character.id { return (cached.directions, cached.reactions) }
        guard let directions = Self.cut(character.id + "-directions"),
              let reactions = Self.cut(character.id + "-reactions") else { return nil }
        cached = (character.id, directions, reactions)
        return (directions, reactions)
    }

    /// A sheet cut into its nine cells, row by row.
    nonisolated static func cut(_ name: String) -> [CGImage]? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "heic", subdirectory: "Mascots"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let sheet = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return cells(of: sheet)
    }

    /// A small picture of a character looking straight ahead, for the picker.
    nonisolated static func thumbnail(_ character: MascotCharacter, pixels: Int = 192) -> CGImage? {
        guard let url = Bundle.main.url(forResource: character.id + "-directions", withExtension: "heic", subdirectory: "Mascots"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceThumbnailMaxPixelSize: pixels * 3]
        guard let sheet = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return cells(of: sheet)?[MascotMotion.Cell.center]
    }

    private nonisolated static func cells(of sheet: CGImage) -> [CGImage]? {
        let side = sheet.width / 3
        var cells: [CGImage] = []
        for row in 0..<3 {
            for column in 0..<3 {
                guard let cell = sheet.cropping(to: CGRect(x: column * side, y: row * side, width: side, height: side)) else {
                    return nil
                }
                cells.append(cell)
            }
        }
        return cells
    }
}

/// Where each mascot on screen is, and which way it should look. Fed by the
/// pointer monitor the notch already runs; a direction changes only when the
/// pointer crosses into another sector, so views redraw rarely.
@MainActor
@Observable
final class MascotTracker {
    static let shared = MascotTracker()

    private(set) var directions: [String: Int] = [:]
    /// Goes up by one for each boop asked from outside the view (a click on the ear).
    private(set) var boops: [String: Int] = [:]
    @ObservationIgnored private var centers: [String: NSPoint] = [:]
    @ObservationIgnored private var pointer: NSPoint?

    var isTracking: Bool { !centers.isEmpty }

    func direction(for anchor: String) -> Int {
        directions[anchor] ?? MascotMotion.Cell.center
    }

    func setCenter(_ center: NSPoint?, for anchor: String) {
        centers[anchor] = center
        if center == nil {
            directions[anchor] = nil
        } else if let pointer {
            update(anchor, pointer: pointer)
        }
    }

    func pointerMoved(_ location: NSPoint) {
        pointer = location
        for anchor in centers.keys {
            update(anchor, pointer: location)
        }
    }

    func boop(_ anchor: String) {
        boops[anchor, default: 0] += 1
    }

    private func update(_ anchor: String, pointer: NSPoint) {
        guard let center = centers[anchor] else { return }
        let next = MascotMotion.direction(dx: pointer.x - center.x, dy: pointer.y - center.y,
                                          previous: direction(for: anchor))
        if directions[anchor] != next {
            directions[anchor] = next
        }
    }
}

/// The mascot, looking toward the pointer. A click (or a boop from outside)
/// blinks, then shows a heart, a sparkle or delight; four quick boops make it
/// dizzy.
struct MascotView: View {
    /// Which mascot this is, for the tracker: "home", or the ear's screen.
    let anchor: String
    var size: CGFloat = 104
    var character: MascotCharacter = .chosen

    @State private var reaction: Int?
    @State private var counter = BoopCounter()
    @State private var squashes = 0
    @State private var reactionTask: Task<Void, Never>?
    @Environment(\.snapshotMode) private var snapshotMode
    private var tracker: MascotTracker { .shared }

    var body: some View {
        let cells = MascotSprites.shared.cells(for: character)
        let image = reaction.flatMap { cells?.reactions[$0] }
            ?? cells?.directions[snapshotMode ? MascotMotion.Cell.downLeft : tracker.direction(for: anchor)]
        Group {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                Color.clear
            }
        }
        .frame(width: size, height: size)
        .keyframeAnimator(initialValue: Squash(), trigger: squashes) { content, squash in
            content.scaleEffect(x: squash.x, y: squash.y, anchor: .bottom)
        } keyframes: { _ in
            // page-mascot's squash: 420 ms, wide then tall then settling.
            KeyframeTrack(\.x) {
                CubicKeyframe(1.10, duration: 0.076)
                CubicKeyframe(0.95, duration: 0.113)
                CubicKeyframe(1.03, duration: 0.113)
                CubicKeyframe(1, duration: 0.118)
            }
            KeyframeTrack(\.y) {
                CubicKeyframe(0.86, duration: 0.076)
                CubicKeyframe(1.08, duration: 0.113)
                CubicKeyframe(0.97, duration: 0.113)
                CubicKeyframe(1, duration: 0.118)
            }
        }
        .background {
            if !snapshotMode {
                ScreenCenterReader { tracker.setCenter($0, for: anchor) }
            }
        }
        .onDisappear { tracker.setCenter(nil, for: anchor) }
        .onChange(of: tracker.boops[anchor]) { _, _ in boop() }
        .accessibilityElement()
        .accessibilityLabel(character.name)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { boop() }
    }

    func boop() {
        if !Motion.reduceMotion {
            squashes += 1
        }
        Haptics.tick()
        let outcome = counter.boop(at: Date())
        reactionTask?.cancel()
        if outcome == MascotMotion.Reaction.dizzy {
            reaction = MascotMotion.Reaction.dizzy
            reactionTask = Task {
                try? await Task.sleep(for: .milliseconds(1100))
                guard !Task.isCancelled else { return }
                reaction = nil
            }
            return
        }
        let payoff = outcome
        reaction = MascotMotion.Reaction.blink
        reactionTask = Task {
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            reaction = payoff
            try? await Task.sleep(for: .milliseconds(560))
            guard !Task.isCancelled else { return }
            reaction = nil
        }
    }

    private struct Squash {
        var x: CGFloat = 1
        var y: CGFloat = 1
    }
}

/// Reports the centre of the view it sits behind, in screen coordinates,
/// whenever it moves.
private struct ScreenCenterReader: NSViewRepresentable {
    let report: (NSPoint?) -> Void

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.report = report
        return view
    }

    func updateNSView(_ view: ReaderView, context: Context) {
        view.report = report
        view.reportCenter()
    }

    final class ReaderView: NSView {
        var report: ((NSPoint?) -> Void)?
        private var last: NSPoint?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            reportCenter()
        }

        override func setFrameOrigin(_ origin: NSPoint) {
            super.setFrameOrigin(origin)
            reportCenter()
        }

        override func setFrameSize(_ size: NSSize) {
            super.setFrameSize(size)
            reportCenter()
        }

        func reportCenter() {
            guard let window else {
                if last != nil {
                    last = nil
                    let report = report
                    DispatchQueue.main.async { report?(nil) }
                }
                return
            }
            let rect = window.convertToScreen(convert(bounds, to: nil))
            let center = NSPoint(x: rect.midX, y: rect.midY)
            guard center != last else { return }
            last = center
            // Not during SwiftUI's update: the tracker it tells is observed.
            let report = report
            DispatchQueue.main.async { report?(center) }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
