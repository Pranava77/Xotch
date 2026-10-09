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
    /// The poses a turn passes through on the way to `to`, one step of the
    /// 3 × 3 grid at a time, ending at `to`: left to right goes by straight
    /// ahead, as a head would.
    static func path(from: Int, to: Int) -> [Int] {
        var col = from % 3, row = from / 3
        let targetCol = to % 3, targetRow = to / 3
        var steps: [Int] = []
        while col != targetCol || row != targetRow {
            col += (targetCol - col).signum()
            row += (targetRow - row).signum()
            steps.append(row * 3 + col)
        }
        return steps
    }

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

    #if DEBUG
    /// Points a mascot at a pose, as if the pointer had moved: `debug.sh mascot-look home:5`.
    func debugLook(_ anchor: String, _ cell: Int) {
        directions[anchor] = cell
    }
    #endif

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
            if snapshotMode {
                // ImageRenderer can't draw AppKit views, so snapshots get a still picture.
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                }
            } else {
                MascotLayer(image: image, reacting: reaction != nil, directions: cells?.directions,
                            direction: tracker.direction(for: anchor), squashes: squashes,
                            breath: size < 60 ? 0.015 : 0.025, phase: Double(abs(anchor.hashValue % 1000)) / 1000)
            }
        }
        .frame(width: size, height: size)
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

}

/// The mascot drawn by Core Animation, so its motion runs in the window
/// server and costs Xotch nothing between changes:
/// - a turn of the head passes through the poses between, dissolving from
///   one to the next with a slight sway, and a reaction crossfades;
/// - it breathes, a slow rise and settle, forever;
/// - a boop squashes it, wide then tall then settling.
/// Reduce Motion keeps it still and swaps pictures at once.
private struct MascotLayer: NSViewRepresentable {
    let image: CGImage?
    /// Showing a reaction rather than looking somewhere.
    let reacting: Bool
    /// The nine poses, and which one it's looking toward.
    let directions: [CGImage]?
    let direction: Int
    let squashes: Int
    /// How far a breath stretches it, as a fraction of its height.
    let breath: CGFloat
    /// Where in the breath it starts, 0...1, so two mascots don't breathe in step.
    let phase: Double

    func makeNSView(context: Context) -> MascotLayerView {
        MascotLayerView(breath: breath, phase: phase)
    }

    func updateNSView(_ view: MascotLayerView, context: Context) {
        if !reacting, let directions, directions.indices.contains(direction) {
            view.look(direction, poses: directions)
        } else {
            view.show(image)
        }
        view.squash(count: squashes)
    }
}

final class MascotLayerView: NSView {
    /// Breathes: scaled from the bottom edge, so the feet stay put.
    private let body = CALayer()
    /// Squashes on a boop, inside the breath.
    private let spring = CALayer()
    /// The picture.
    private let sprite = CALayer()
    private let breath: CGFloat
    private let phase: Double
    private var squashes = 0
    private var shown: CGImage?
    /// The pose it's looking toward, while it's looking rather than reacting.
    private var looking: Int?

    /// How long a reaction takes to fade across.
    static let fade: CFTimeInterval = 0.18
    /// Each step of a turn, from one pose to the next.
    static let step: CFTimeInterval = 0.13
    static let breathLength: CFTimeInterval = 2.6

    init(breath: CGFloat, phase: Double) {
        self.breath = breath
        self.phase = phase
        super.init(frame: .zero)
        wantsLayer = true
        for layer in [body, spring] {
            layer.anchorPoint = CGPoint(x: 0.5, y: 0)
        }
        sprite.contentsGravity = .resizeAspect
        sprite.minificationFilter = .trilinear
        layer?.addSublayer(body)
        body.addSublayer(spring)
        spring.addSublayer(sprite)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in [body, spring] {
            layer.bounds = bounds
            layer.position = CGPoint(x: bounds.midX, y: 0)
        }
        // body and spring are positioned by their bottom edge.
        body.position = CGPoint(x: bounds.midX, y: bounds.minY)
        spring.position = CGPoint(x: bounds.midX, y: 0)
        sprite.frame = bounds
        CATransaction.commit()
        breathe()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        sprite.contentsScale = window?.backingScaleFactor ?? 2
    }

    /// Turns toward `direction` through the poses between, as one keyframe
    /// animation of the picture (Core Animation dissolves each into the
    /// next), with a slight sway toward the turn that settles as it lands.
    func look(_ direction: Int, poses: [CGImage]) {
        let image = poses[direction]
        guard image !== shown else {
            looking = direction
            return
        }
        // The first picture, or back from a reaction: a plain crossfade.
        guard let from = looking, shown === poses[from], !Motion.reduceMotion else {
            looking = direction
            show(image)
            return
        }
        looking = direction
        let route = [from] + MascotMotion.path(from: from, to: direction)
        let turn = CAKeyframeAnimation(keyPath: "contents")
        turn.values = route.map { poses[$0] }
        turn.calculationMode = .linear
        turn.duration = Self.step * Double(route.count - 1) + 0.05
        turn.timingFunction = CAMediaTimingFunction(controlPoints: 0.3, 0, 0.2, 1)
        sprite.removeAnimation(forKey: "turn")
        sprite.add(turn, forKey: "turn")
        // Lean a little the way it's turning, then settle.
        let across = CGFloat(direction % 3 - from % 3), down = CGFloat(direction / 3 - from / 3)
        let size = max(bounds.width, 1)
        let sway = CAKeyframeAnimation(keyPath: "transform.translation.x")
        sway.values = [0, across * size * 0.035, 0]
        let dip = CAKeyframeAnimation(keyPath: "transform.translation.y")
        dip.values = [0, -down * size * 0.025, 0]
        let tilt = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        tilt.values = [0, -across * 0.045, 0]
        let lean = CAAnimationGroup()
        lean.animations = [sway, dip, tilt]
        for track in [sway, dip, tilt] {
            track.keyTimes = [0, 0.4, 1]
            track.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeInEaseOut)]
            track.isAdditive = true
        }
        lean.duration = turn.duration + 0.18
        sprite.add(lean, forKey: "lean")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sprite.contents = image
        CATransaction.commit()
        shown = image
    }

    func show(_ image: CGImage?) {
        guard image !== shown else { return }
        let first = shown == nil
        shown = image
        if !first, !Motion.reduceMotion {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = Self.fade
            fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            sprite.add(fade, forKey: "turn")
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sprite.contents = image
        CATransaction.commit()
    }

    /// page-mascot's 420 ms squash, played once per boop.
    func squash(count: Int) {
        guard count != squashes else { return }
        squashes = count
        guard !Motion.reduceMotion else { return }
        let times: [NSNumber] = [0, 0.18, 0.45, 0.72, 1]
        let x = CAKeyframeAnimation(keyPath: "transform.scale.x")
        x.values = [1, 1.10, 0.95, 1.03, 1]
        let y = CAKeyframeAnimation(keyPath: "transform.scale.y")
        y.values = [1, 0.86, 1.08, 0.97, 1]
        let group = CAAnimationGroup()
        for track in [x, y] {
            track.keyTimes = times
            track.timingFunctions = [CAMediaTimingFunction(name: .easeIn), CAMediaTimingFunction(name: .easeOut),
                                     CAMediaTimingFunction(name: .easeInEaseOut), CAMediaTimingFunction(name: .easeInEaseOut)]
        }
        group.animations = [x, y]
        group.duration = 0.42
        spring.add(group, forKey: "squash")
    }

    private func breathe() {
        guard !Motion.reduceMotion, body.animation(forKey: "breath") == nil, bounds.height > 0 else { return }
        let up = CABasicAnimation(keyPath: "transform.scale.y")
        up.fromValue = 1
        up.toValue = 1 + breath
        let narrow = CABasicAnimation(keyPath: "transform.scale.x")
        narrow.fromValue = 1
        narrow.toValue = 1 - breath * 0.4
        let group = CAAnimationGroup()
        group.animations = [up, narrow]
        group.duration = Self.breathLength / 2
        group.autoreverses = true
        group.repeatCount = .infinity
        group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        group.timeOffset = phase * Self.breathLength
        body.add(group, forKey: "breath")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    #if DEBUG
    /// For the self-test: whether the layers are set up to move.
    var debugState: String {
        "layers=\(sprite.superlayer === spring && spring.superlayer === body) breathing=\(body.animation(forKey: "breath") != nil)"
    }

    /// The last turn's route, for `debug.sh status`: how many poses it passed through.
    var debugTurn: String {
        let turn = sprite.animation(forKey: "turn") as? CAKeyframeAnimation
        return "turning=\(turn != nil) poses=\(turn?.values?.count ?? 0) looking=\(looking.map(String.init) ?? "-")"
    }
    #endif
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
