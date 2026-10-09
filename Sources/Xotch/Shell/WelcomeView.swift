import AppKit
import SwiftUI

/// The first thing Xotch shows, once: "hello" writing itself in the notch the
/// way a new Mac greets you, in a few languages, then three things to know.
/// It comes back from the menu bar's Welcome to Xotch.
struct WelcomeView: View {
    static let size = CGSize(width: 760, height: 320)

    let notchHeight: CGFloat
    @State private var showsSetup: Bool
    @State private var greeted = false
    @Environment(\.snapshotMode) private var snapshotMode

    /// `atSetup` skips the hello, for snapshots of the second page.
    init(notchHeight: CGFloat, atSetup: Bool = false) {
        self.notchHeight = notchHeight
        _showsSetup = State(initialValue: atSetup)
    }

    /// Snapshots can't wait for the first word, so they show it all.
    private var ready: Bool { greeted || snapshotMode }

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: notchHeight)
            ZStack {
                if showsSetup {
                    setup
                        .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                                removal: .opacity))
                } else {
                    hello
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .foregroundStyle(Theme.ink)
        .animation(Motion.switchModule, value: showsSetup)
        .task {
            // The button arrives once the first word has written itself.
            try? await Task.sleep(for: .seconds(snapshotMode ? 0 : 1.8))
            withAnimation(Motion.activity) { greeted = true }
        }
    }

    // MARK: The hello

    private var hello: some View {
        VStack(spacing: 10) {
            HelloLettering()
                .frame(width: 420, height: 130)
            Text("Welcome to Xotch")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.secondaryInk)
                .opacity(ready ? 1 : 0)
            Button("Continue") { showsSetup = true }
                .buttonStyle(PillButtonStyle())
                .keyboardShortcut(.defaultAction)
                .opacity(ready ? 1 : 0)
                .padding(.top, 4)
                .debugFrame("welcome.continue")
        }
    }

    // MARK: Three things to know

    private var setup: some View {
        VStack(spacing: 14) {
            Text("Three things to know")
                .font(.system(size: 17, weight: .semibold))
            HStack(alignment: .top, spacing: 12) {
                Step(symbol: "cursorarrow.motionlines", title: "Rest on the notch",
                     detail: "Hover to peek, and keep the pointer there to open it. Click to keep it open; Esc closes it.")
                Step(symbol: "sparkles", title: "Ask, and it acts",
                     detail: "Press ⌘⇧Space in any app. The AI changes things only after you click Allow.",
                     action: ("Set Up AI…", { SettingsWindow.show(.ai) }))
                if WhistleEngine.isSupported {
                    Step(symbol: "mic.fill", title: "Talk instead of typing",
                         detail: "Hold Fn and speak; the words appear where you're typing, transcribed on this Mac.",
                         action: ("Set Up Dictation…", { SettingsWindow.show(.dictation) }))
                } else {
                    Step(symbol: "command", title: "One shortcut for everything",
                         detail: "Press ⌘K in the open notch to start a timer, take a screenshot or add a to-do.")
                }
            }
            Button("Start Using Xotch") { ScreenManager.shared.finishWelcome() }
                .buttonStyle(PillButtonStyle())
                .keyboardShortcut(.defaultAction)
                .debugFrame("welcome.done")
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 18)
    }
}

private struct Step: View {
    let symbol: String
    let title: String
    let detail: String
    var action: (String, () -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(height: 22)
            Text(title)
                .font(.system(size: 13.5, weight: .semibold))
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let action {
                Button(action.0, action: action.1)
                    .buttonStyle(PillButtonStyle(prominent: false))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 136, alignment: .topLeading)
        .background(Theme.fill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

// MARK: - Hello, written out

/// "hello" in cursive, written stroke by stroke through a warm gradient, then
/// filled, then the next language. Core Animation draws it, so it costs Xotch
/// nothing while it writes. Snapshots and Reduce Motion get it written already.
private struct HelloLettering: View {
    @Environment(\.snapshotMode) private var snapshotMode

    var body: some View {
        if snapshotMode || Motion.reduceMotion {
            Text("hello")
                .font(.custom(HelloLetteringView.fontName, size: 96))
                .foregroundStyle(LinearGradient(colors: HelloLetteringView.colors.map { Color(nsColor: $0) },
                                                startPoint: .leading, endPoint: .trailing))
        } else {
            HelloLayer()
        }
    }
}

private struct HelloLayer: NSViewRepresentable {
    func makeNSView(context: Context) -> HelloLetteringView { HelloLetteringView() }
    func updateNSView(_ view: HelloLetteringView, context: Context) {}
}

final class HelloLetteringView: NSView {
    static let fontName = "SnellRoundhand-Bold"
    static let words = ["hello", "hola", "bonjour", "ciao", "hallo", "olá"]
    static let colors: [NSColor] = [
        NSColor(red: 1.0, green: 0.62, blue: 0.04, alpha: 1),
        NSColor(red: 1.0, green: 0.22, blue: 0.37, alpha: 1),
        NSColor(red: 0.75, green: 0.35, blue: 0.95, alpha: 1),
        NSColor(red: 0.39, green: 0.82, blue: 1.0, alpha: 1),
    ]
    /// How long a word takes to write, and how long it then stays.
    static let writing: CFTimeInterval = 1.5
    static let holding: CFTimeInterval = 1.1

    private let gradient = CAGradientLayer()
    private let letters = CAShapeLayer()
    private var task: Task<Void, Never>?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        gradient.colors = Self.colors.map(\.cgColor)
        gradient.startPoint = CGPoint(x: 0, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
        letters.fillColor = NSColor.clear.cgColor
        letters.strokeColor = NSColor.white.cgColor
        letters.lineWidth = 2.2
        letters.lineCap = .round
        letters.lineJoin = .round
        letters.strokeEnd = 0
        gradient.mask = letters
        layer?.addSublayer(gradient)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.frame = bounds
        letters.frame = bounds
        CATransaction.commit()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        task?.cancel()
        guard window != nil else { return }
        task = Task { @MainActor [weak self] in
            var index = 0
            while !Task.isCancelled {
                guard let self else { return }
                self.write(Self.words[index % Self.words.count])
                try? await Task.sleep(for: .seconds(Self.writing + Self.holding))
                guard !Task.isCancelled else { return }
                self.fadeOut()
                try? await Task.sleep(for: .seconds(0.45))
                index += 1
            }
        }
    }

    /// Traces the word's outline, then fills it.
    private func write(_ word: String) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        letters.path = Self.path(for: word, in: bounds)
        letters.opacity = 1
        letters.fillColor = NSColor.clear.cgColor
        letters.strokeEnd = 1
        CATransaction.commit()

        let trace = CABasicAnimation(keyPath: "strokeEnd")
        trace.fromValue = 0
        trace.toValue = 1
        trace.duration = Self.writing
        trace.timingFunction = CAMediaTimingFunction(controlPoints: 0.45, 0.05, 0.35, 1)
        letters.add(trace, forKey: "trace")

        let fill = CABasicAnimation(keyPath: "fillColor")
        fill.fromValue = NSColor.clear.cgColor
        fill.toValue = NSColor.white.cgColor
        fill.beginTime = CACurrentMediaTime() + Self.writing * 0.7
        fill.duration = Self.writing * 0.45
        fill.fillMode = .backwards
        fill.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        letters.add(fill, forKey: "fill")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        letters.fillColor = NSColor.white.cgColor
        CATransaction.commit()
    }

    private func fadeOut() {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = 0.4
        letters.add(fade, forKey: "fade")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        letters.opacity = 0
        CATransaction.commit()
    }

    /// The word's letter outlines in the cursive font, sized to fit and centred.
    static func path(for word: String, in bounds: CGRect) -> CGPath {
        let font = CTFontCreateWithName(fontName as CFString, 96, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: word, attributes: [.font: font]))
        let outline = CGMutablePath()
        for run in (CTLineGetGlyphRuns(line) as? [CTRun]) ?? [] {
            let count = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
            let runFont = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] as! CTFont
            for (glyph, position) in zip(glyphs, positions) {
                if let shape = CTFontCreatePathForGlyph(runFont, glyph, nil) {
                    outline.addPath(shape, transform: CGAffineTransform(translationX: position.x, y: position.y))
                }
            }
        }
        let box = outline.boundingBoxOfPath
        guard box.width > 0, box.height > 0, bounds.width > 0 else { return outline }
        let scale = min(bounds.width * 0.92 / box.width, bounds.height * 0.9 / box.height)
        var fit = CGAffineTransform(translationX: bounds.midX, y: bounds.midY)
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: -box.midX, y: -box.midY)
        return outline.copy(using: &fit) ?? outline
    }

    #if DEBUG
    /// For the self-test: every word has an outline to write.
    static var debugWordsDrawable: Bool {
        words.allSatisfy { !path(for: $0, in: CGRect(x: 0, y: 0, width: 420, height: 130)).isEmpty }
    }
    #endif
}
