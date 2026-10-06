import QuartzCore
import SwiftUI

/// The root view inside the notch panel: one black shape whose size and
/// content follow the model's phase.
struct ShellView: View {
    let model: NotchViewModel
    let actions: any NotchActions

    @AppStorage(SettingsKey.moduleOrder) private var moduleOrder = ""
    @AppStorage(SettingsKey.hiddenModules) private var hiddenModules = ""
    @Environment(\.snapshotMode) private var snapshotMode
    @Namespace private var namespace
    @State private var isDropTarget = false

    var body: some View {
        let shape = NotchShape(shoulderRadius: model.shoulder, cornerRadius: model.cornerRadius)
        let size = model.bodySize
        let width = size.width + model.shoulder * 2
        let modules = ModuleRegistry.visible(order: moduleOrder, hidden: hiddenModules)
        let selected = modules.first { $0.id == model.selectedModuleID } ?? modules[0]
        let palette = Theme.palette
        let glow = model.phase == .open && palette.glowStrength > 0 ? (selected.tint ?? palette.glow?.color) : nil

        ZStack(alignment: .top) {
            NotchSurface(shape: shape, isOpen: model.phase == .open)
                .shadow(color: .black.opacity(model.phase == .open ? 0.45 : 0), radius: 22, y: 10)

            ZStack(alignment: .top) {
                if let glow {
                    // Reaches the far corner whatever the module asked for; a
                    // fixed radius left a dark corner once the notch grew.
                    RadialGradient(colors: [glow.opacity(palette.glowStrength), glow.opacity(0)],
                                   center: .topLeading, startRadius: 10,
                                   endRadius: max(520, width * 0.62))
                        .transition(.opacity)
                }
                if model.showsActivity {
                    LiveActivityBar(activity: model.activities.current,
                                    companion: model.activities.companion,
                                    mascotAnchor: model.earMascotAnchor,
                                    earWidth: model.earWidth,
                                    notchSize: model.closedSize,
                                    position: model.activities.livePosition,
                                    namespace: namespace)
                        .transition(.blurFade)
                }
                if model.phase == .open {
                    OpenContent(model: model, modules: modules, selected: selected,
                                actions: actions, namespace: namespace)
                        .frame(width: model.openSize.width, height: model.openSize.height, alignment: .top)
                        .transition(.blurScale)
                }
                if model.phase == .open {
                    RippleOverlay(trigger: model.dropCount, origin: model.dropPoint, tint: palette.accent)
                        .frame(width: model.openSize.width, height: model.openSize.height)
                }
                if isDropTarget {
                    shape
                        .stroke(Theme.accent, lineWidth: 2)
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, model.shoulder)
            .frame(width: width, height: size.height, alignment: .top)
            .clipShape(shape)
            .animation(Motion.switchModule, value: glow)
        }
        .frame(width: width, height: size.height)
        .contentShape(shape)
        .onTapGesture { actions.tapped() }
        .modifier(ShelfDropTarget(onDrop: { location in
            // The drop point is in this view; the ripple is drawn inside the shoulders.
            model.dropPoint = CGPoint(x: location.x - model.shoulder, y: location.y)
            model.dropCount += 1
            actions.select(moduleID: "shelf")
        }, isTargeted: $isDropTarget))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .overlay {
            if !snapshotMode {
                CelebrationBurst(trigger: model.activities.celebrations,
                                 originFromTop: size.height - 4,
                                 width: size.width)
                    .allowsHitTesting(false)
            }
        }
        .ignoresSafeArea()
    }
}

// MARK: - Open state

private struct OpenContent: View {
    let model: NotchViewModel
    let modules: [any NotchModule]
    let selected: any NotchModule
    let actions: any NotchActions
    let namespace: Namespace.ID
    @State private var showsMore = false

    var body: some View {
        VStack(spacing: 0) {
            topRow
                .frame(height: model.closedSize.height)

            ZStack(alignment: .topLeading) {
                selected.expandedView()
                    .id(selected.id)
                    .transition(.push(from: model.switchEdge))
            }
            // minHeight 0: a tall module is clipped instead of growing the notch.
            .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
            .offset(x: model.rubberBand)
            .padding(.horizontal, 22)
            .padding(.top, 10)
            .padding(.bottom, 14)
            .clipped()
        }
        .foregroundStyle(Theme.ink)
        .overlay(alignment: .topLeading) {
            if showsMore {
                ZStack(alignment: .topLeading) {
                    Theme.surface.opacity(0.55)
                        .contentShape(Rectangle())
                        .onTapGesture { withAnimation(Motion.press) { showsMore = false } }
                        .transition(.opacity)
                    MoreModules(modules: moreModules.map(\.info), selectedID: selected.id) { id in
                        withAnimation(Motion.press) { showsMore = false }
                        actions.select(moduleID: id)
                    }
                    .padding(.top, model.closedSize.height + 2)
                    .padding(.leading, 18)
                    .transition(.scale(scale: 0.96, anchor: .topLeading).combined(with: .opacity))
                }
                .foregroundStyle(Theme.ink)
            }
        }
        .onChange(of: model.palette.isOpen) { _, isOpen in
            if isOpen { showsMore = false }
        }
        .overlay(alignment: .top) {
            if model.palette.isOpen {
                ZStack(alignment: .top) {
                    Theme.surface.opacity(0.55)
                        .contentShape(Rectangle())
                        .onTapGesture { actions.closePalette() }
                        .transition(.opacity)
                    CommandPaletteView(model: model, actions: actions)
                        .padding(.top, model.closedSize.height + 4)
                        .transition(.scale(scale: 0.96, anchor: .top).combined(with: .opacity))
                }
                .foregroundStyle(Theme.ink)
            }
        }
    }

    /// The first few modules get a tab beside the camera. One you reach through
    /// "more" or ⌘K takes the last tab's place while it's open.
    private var tabModules: [any NotchModule] {
        var tabs = Array(modules.prefix(Layout.headerTabs))
        if !tabs.contains(where: { $0.id == selected.id }) {
            tabs[tabs.count - 1] = selected
        }
        return tabs
    }

    private var moreModules: [any NotchModule] {
        let shown = Set(tabModules.map(\.id))
        return modules.filter { !shown.contains($0.id) }
    }

    /// Tabs left of the camera housing; palette and pin on the right.
    private var topRow: some View {
        HStack(spacing: 0) {
            // While a volume or brightness key is held, the header shows the
            // level: with the notch open there are no ears to show it in.
            Group {
                if let hud = model.activities.hud, case .level(let value) = hud.content {
                    KeyLevelPill(symbol: hud.symbol, value: value)
                        .transition(.opacity)
                } else {
                    HeaderTabs(tabs: tabModules.map(\.info),
                               hasMore: !moreModules.isEmpty,
                               showsMore: showsMore,
                               selectedID: selected.id,
                               namespace: namespace,
                               select: { id in
                                   showsMore = false
                                   actions.select(moduleID: id)
                               },
                               toggleMore: { withAnimation(Motion.press) { showsMore.toggle() } })
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Room for the camera housing, which sits over the open notch's
            // header. A drawn notch has nothing there, so it only needs a gap.
            Color.clear
                .frame(width: model.hasHardwareNotch ? model.closedSize.width : 24)

            HStack(spacing: 2) {
                Spacer(minLength: 0)
                // Capture shows its own timer and Stop button.
                if let started = CaptureService.shared.recordingStarted, selected.id != "capture" {
                    RecordingPill(started: started)
                        .padding(.trailing, 6)
                        .transition(.scale.combined(with: .opacity))
                }
                PaletteButton { actions.togglePalette() }
                PinButton(isPinned: model.isPinned) { actions.togglePin() }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 22)
    }
}

/// A level bar with its icon, for the open notch's header.
private struct KeyLevelPill: View {
    let symbol: String
    let value: Double

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 18)
            LevelBar(value: value, tint: Theme.accent)
                .frame(width: 130)
            Text("\(Int((value * 100).rounded()))")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Theme.secondaryInk)
                .frame(width: 26, alignment: .leading)
        }
    }
}

private struct PaletteButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 1) {
                Image(systemName: "command")
                Text("K")
            }
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(Theme.tertiaryInk)
            .padding(.horizontal, 6)
            .frame(height: 20)
            .xotchGlass(Capsule(), interactive: true, fallback: Theme.fill)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Command palette  ⌘K")
        .accessibilityLabel("Command palette")
    }
}

/// Shown in every module while a screen recording runs; click to stop.
private struct RecordingPill: View {
    let started: Date

    var body: some View {
        Button {
            CaptureService.shared.stopRecording()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 8, weight: .bold))
                Text(started, style: .timer)
                    .monospacedDigit()
            }
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(Capsule().fill(Theme.negative))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Stop recording")
        .accessibilityLabel("Stop recording")
    }
}

private struct PinButton: View {
    let isPinned: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isPinned ? "pin.fill" : "pin")
                .font(.system(size: 11, weight: .semibold))
                .rotationEffect(.degrees(isPinned ? 0 : 45))
                .foregroundStyle(isPinned ? Theme.accent : Theme.tertiaryInk)
                .frame(width: 26, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isPinned ? "Unpin: close when the pointer leaves" : "Pin: keep the notch open")
        .accessibilityLabel(isPinned ? "Unpin notch" : "Pin notch open")
        .animation(Motion.switchModule, value: isPinned)
    }
}

// MARK: - Activity state

/// Live content in the "ears" either side of the camera housing.
private struct LiveActivityBar: View {
    let activity: LiveActivity?
    /// Holds the left ear; an activity's icon then moves to the right ear.
    let companion: EarCompanion
    let mascotAnchor: String
    private var adiyogi: Bool { companion != .none }
    let earWidth: CGFloat
    let notchSize: CGSize
    /// Which of several live activities is showing, for the dots.
    let position: (index: Int, count: Int)?
    let namespace: Namespace.ID

    var body: some View {
        HStack(spacing: 0) {
            Group {
                if companion == .mascot {
                    MascotView(anchor: mascotAnchor, size: 30)
                        .transition(.opacity)
                } else if companion == .adiyogi {
                    AdiyogiMark()
                        .transition(.opacity)
                } else if let activity {
                    icon(activity)
                        .matchedGeometryEffect(id: "icon-\(activity.moduleID)", in: namespace)
                        .id(activity.id)
                        .transition(.opacity)
                }
            }
            .padding(.leading, 12)
            .frame(width: earWidth, alignment: .leading)

            Color.clear
                .frame(width: notchSize.width)

            HStack(spacing: 6) {
                if let activity {
                    if adiyogi {
                        // The left ear is taken, so the icon sits by its content.
                        icon(activity)
                            .scaleEffect(0.85)
                            .matchedGeometryEffect(id: "icon-\(activity.moduleID)", in: namespace)
                            .id(activity.id)
                            .transition(.opacity)
                    }
                    // A new identity per activity: taking turns then fades one
                    // view out and the next in. Changing the text in place
                    // made SwiftUI morph the glyphs, drawing them on the CPU
                    // every frame (measured: about 4% CPU with turns every 6 s).
                    trailing(activity)
                        .id(activity.id)
                        .transition(.opacity)
                }
            }
                .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .padding(.trailing, 12)
                .frame(width: earWidth, alignment: .trailing)
                .overlay(alignment: .trailing) {
                    if let position {
                        WaitingDots(index: position.index, count: position.count)
                            .padding(.trailing, 4)
                            .transition(.opacity)
                    }
                }
        }
        .frame(height: notchSize.height)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func icon(_ activity: LiveActivity) -> some View {
        if let image = activity.image {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 22, height: 22)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        } else {
            ZStack {
                if let pulse = activity.pulse {
                    PulseHalo(pulse: pulse, tint: activity.tint)
                        .frame(width: 26, height: 26)
                }
                if let progress = activity.progress {
                    ProgressRing(progress: progress, tint: activity.tint)
                        .frame(width: 23, height: 23)
                }
                let symbol = Image(systemName: activity.symbol)
                    .font(.system(size: activity.progress == nil ? 13 : 10, weight: .semibold))
                    .foregroundStyle(activity.tint)
                // Pops for something new, not for each turn in the round.
                if position == nil {
                    symbol.popOnChange(of: activity.id)
                } else {
                    symbol
                }
            }
            .frame(width: 26, height: 26)
        }
    }

    @ViewBuilder private func trailing(_ activity: LiveActivity) -> some View {
        switch activity.content {
        case .text(let text):
            Text(text)
                .contentTransition(.numericText())
        case .countdown(let until):
            Text(timerInterval: Date.now...max(until, .now), countsDown: true)
                .multilineTextAlignment(.trailing)
                .foregroundStyle(activity.tint)
        case .stopwatch(let since):
            Text(since, style: .timer)
                .multilineTextAlignment(.trailing)
                .foregroundStyle(activity.tint)
        case .playing:
            EqualizerBars(tint: activity.tint)
                .frame(width: EqualizerView.width, height: EqualizerView.height)
        case .listening:
            EqualizerBars(tint: activity.tint, source: .microphone)
                .frame(width: EqualizerView.width, height: EqualizerView.height)
        case .level(let value):
            LevelBar(value: value, tint: activity.tint)
                .frame(width: max(activity.earWidth - 30, 30))
        case .ticker(let lines):
            TickerText(lines: lines)
        }
    }
}

/// A wave of bars across the ear while music plays. Core Animation runs them
/// in the window server, so they cost Xotch almost nothing even over hours of music.
private struct EqualizerBars: View {
    let tint: Color
    var source: EqualizerView.Source = .music
    @Environment(\.snapshotMode) private var snapshotMode

    private static let stillHeights: [CGFloat] = [0.3, 0.55, 0.8, 0.5, 0.95, 0.7, 1, 0.6, 0.85, 0.45, 0.65, 0.35]

    var body: some View {
        Group {
            if snapshotMode || Motion.reduceMotion {
                HStack(spacing: EqualizerView.gap) {
                    ForEach(Array(Self.stillHeights.enumerated()), id: \.offset) { _, height in
                        Capsule().fill(tint)
                            .frame(width: EqualizerView.barWidth, height: EqualizerView.height * height)
                    }
                }
            } else {
                EqualizerLayers(tint: NSColor(tint), source: source)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(source == .music ? "Playing" : "Listening")
    }
}

private struct EqualizerLayers: NSViewRepresentable {
    let tint: NSColor
    let source: EqualizerView.Source

    func makeNSView(context: Context) -> EqualizerView {
        EqualizerView(source: source)
    }

    func updateNSView(_ view: EqualizerView, context: Context) {
        view.tint = tint
    }
}

/// Bars that follow the music when real audio levels are on (see AudioLevels),
/// bass on the left, and ripple by themselves otherwise. While dictating they
/// show the microphone instead: the last dozen loudness readings, newest on
/// the right, so your voice scrolls across as a waveform.
final class EqualizerView: NSView {
    enum Source {
        case music, microphone
    }

    private let source: Source
    /// One bar per band of `SpectrumAnalyzer`, spread across most of the ear.
    static let barCount = SpectrumAnalyzer.bandCount
    static let barWidth: CGFloat = 2.5
    static let gap: CGFloat = 2
    static let height: CGFloat = 16
    static var width: CGFloat { CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * gap }

    private static let durations: [CFTimeInterval] = [0.42, 0.55, 0.37, 0.49, 0.46, 0.4]
    /// Each bar starts a little after the one to its left, so a ripple runs across.
    private static let stagger: CFTimeInterval = 0.06
    private var bars: [CALayer] = []
    private var levelTimer: Timer?
    private var isFollowingLevels = false
    private var isAcquired = false

    var tint: NSColor = .white {
        didSet {
            guard tint != oldValue else { return }
            bars.forEach { $0.backgroundColor = tint.cgColor }
        }
    }

    init(source: Source = .music) {
        self.source = source
        super.init(frame: .zero)
        // The microphone's bars only ever follow the voice.
        isFollowingLevels = source == .microphone
        wantsLayer = true
        for _ in 0..<Self.barCount {
            let bar = CALayer()
            bar.cornerRadius = Self.barWidth / 2
            bar.backgroundColor = tint.cgColor
            layer?.addSublayer(bar)
            bars.append(bar)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, bar) in bars.enumerated() {
            bar.bounds = CGRect(x: 0, y: 0, width: Self.barWidth, height: bounds.height)
            bar.position = CGPoint(x: CGFloat(index) * (Self.barWidth + Self.gap) + Self.barWidth / 2, y: bounds.midY)
        }
        CATransaction.commit()
        if !isFollowingLevels {
            startBouncing()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        levelTimer?.invalidate()
        levelTimer = nil
        if isAcquired {
            AudioLevels.shared.release()
            isAcquired = false
        }
        guard window != nil else { return }
        if source == .music {
            guard AudioLevels.shared.isEnabled else { return }
            AudioLevels.shared.acquire()
            isAcquired = true
        }
        // 20 updates a second, only while the bars are on screen.
        let timer = Timer(timeInterval: 0.05, repeats: true) { @Sendable [weak self] _ in
            MainActor.assumeIsolated { self?.followLevels() }
        }
        timer.tolerance = 0.01
        RunLoop.main.add(timer, forMode: .common)
        levelTimer = timer
    }

    private func followLevels() {
        let reading = source == .microphone ? DictationService.shared.levels.current() : AudioLevels.shared.current()
        guard let levels = reading else {
            if isFollowingLevels {
                isFollowingLevels = false
                startBouncing()
            }
            return
        }
        if !isFollowingLevels {
            isFollowingLevels = true
            bars.forEach { $0.removeAnimation(forKey: "bounce") }
        }
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.07)
        for (bar, level) in zip(bars, levels) {
            let scale = 0.18 + 0.82 * CGFloat(level)
            bar.transform = CATransform3DMakeScale(1, scale, 1)
        }
        CATransaction.commit()
    }

    private func startBouncing() {
        let middle = CGFloat(bars.count - 1) / 2
        for (index, bar) in bars.enumerated() where bar.animation(forKey: "bounce") == nil {
            // Shorter towards the ends, so the row reads as one wave.
            let taper = 1 - 0.45 * pow(abs(CGFloat(index) - middle) / middle, 2)
            let bounce = CABasicAnimation(keyPath: "transform.scale.y")
            bounce.fromValue = 0.2
            bounce.toValue = taper
            bounce.duration = Self.durations[index % Self.durations.count]
            bounce.autoreverses = true
            bounce.repeatCount = .infinity
            bounce.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            // Started in the past, so every bar moves at once instead of
            // sitting at full height until its turn.
            bounce.beginTime = CACurrentMediaTime() - Double(bars.count - 1 - index) * Self.stagger
            bar.add(bounce, forKey: "bounce")
        }
    }
}

// MARK: - Transitions

private struct BlurModifier: ViewModifier {
    let radius: CGFloat
    func body(content: Content) -> some View {
        content.blur(radius: radius)
    }
}

extension AnyTransition {
    /// Open content blurs and scales in from the top, and fades out.
    static var blurScale: AnyTransition {
        .asymmetric(
            insertion: .modifier(active: BlurModifier(radius: 10), identity: BlurModifier(radius: 0))
                .combined(with: .scale(scale: 0.92, anchor: .top))
                .combined(with: .opacity),
            removal: .modifier(active: BlurModifier(radius: 6), identity: BlurModifier(radius: 0))
                .combined(with: .opacity)
        )
    }

    static var blurFade: AnyTransition {
        .modifier(active: BlurModifier(radius: 6), identity: BlurModifier(radius: 0))
            .combined(with: .opacity)
    }
}

// MARK: - Header tabs

/// Module tabs in one capsule beside the camera. The chosen one widens to show
/// its name; if there isn't room for the name, it stays an icon.
private struct HeaderTabs: View {
    let tabs: [ModuleInfo]
    let hasMore: Bool
    let showsMore: Bool
    let selectedID: String
    let namespace: Namespace.ID
    let select: (String) -> Void
    let toggleMore: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            strip(showsTitle: true)
            strip(showsTitle: false)
        }
    }

    private func strip(showsTitle: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(tabs) { tab in
                let isSelected = tab.id == selectedID
                Button { select(tab.id) } label: {
                    HStack(spacing: 5) {
                        Image(systemName: tab.symbol)
                            .symbolVariant(isSelected ? .fill : .none)
                            .font(.system(size: 11.5, weight: .semibold))
                        if isSelected && showsTitle {
                            Text(tab.title)
                                .font(.system(size: 12, weight: .semibold, design: Theme.fontDesign))
                                .lineLimit(1)
                                .fixedSize()
                        }
                    }
                    .foregroundStyle(isSelected ? Theme.ink : Theme.secondaryInk)
                    .padding(.horizontal, isSelected && showsTitle ? 8 : 0)
                    .frame(minWidth: 23, minHeight: 22)
                    .background {
                        if isSelected {
                            Capsule()
                                .fill(Theme.isRetro ? Theme.accent.opacity(0.55) : Theme.selection)
                                .xotchGloss(Capsule())
                                .matchedGeometryEffect(id: "tab-highlight", in: namespace)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(tab.title)
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .debugFrame("tab.\(tab.id)")
                .animation(Motion.switchModule, value: selectedID)
            }
            if hasMore {
                Button(action: toggleMore) {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 11.5, weight: .bold))
                        .foregroundStyle(showsMore ? Theme.ink : Theme.secondaryInk)
                        .frame(width: 23, height: 22)
                        .background {
                            if showsMore { Capsule().fill(Theme.selection) }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("More modules")
                .accessibilityLabel("More modules")
                .debugFrame("tab.more")
            }
        }
        .padding(2)
        .background(Theme.fill, in: Capsule())
        .xotchGloss(Capsule(), strength: 0.5)
        .fixedSize()
    }
}

/// The modules without a tab, as a small grid under the header.
private struct MoreModules: View {
    let modules: [ModuleInfo]
    let selectedID: String
    let select: (String) -> Void

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(84), spacing: 6), count: 3), spacing: 6) {
            ForEach(modules) { module in
                Button { select(module.id) } label: {
                    VStack(spacing: 5) {
                        Image(systemName: module.symbol)
                            .font(.system(size: 15, weight: .semibold))
                        Text(module.title)
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                    }
                    .foregroundStyle(module.id == selectedID ? Theme.ink : Theme.secondaryInk)
                    .frame(width: 84, height: 56)
                    .contentShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(HoverButtonStyle())
                .accessibilityLabel(module.title)
                .debugFrame("more.\(module.id)")
            }
        }
        .padding(8)
        .fixedSize()
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .xotchGlass(RoundedRectangle(cornerRadius: 16, style: .continuous), gloss: 0.4)
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.raisedFill))
        .shadow(color: .black.opacity(0.4), radius: 14, y: 6)
    }
}
