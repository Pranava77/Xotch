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
                if model.showsActivity, let activity = model.activities.current {
                    LiveActivityBar(activity: activity,
                                    notchSize: model.closedSize,
                                    waiting: model.activities.waitingCount,
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

    var body: some View {
        VStack(spacing: 0) {
            topRow
                .frame(height: model.closedSize.height)

            ZStack(alignment: .topLeading) {
                selected.expandedView()
                    .id(selected.id)
                    .transition(.push(from: model.switchEdge))
            }
            // minHeight 0: a tall module is clipped instead of pushing the dock away.
            .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
            .offset(x: model.rubberBand)
            .padding(.horizontal, 22)
            .padding(.top, 10)
            .padding(.bottom, 8)
            .clipped()

            ModuleDock(modules: modules.map { $0.info },
                       selectedID: selected.id,
                       namespace: namespace) { actions.select(moduleID: $0) }
                .frame(height: Layout.dockHeight)
                .padding(.bottom, 6)
        }
        .foregroundStyle(Theme.ink)
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

    /// Title left of the camera housing; palette and pin on the right.
    private var topRow: some View {
        HStack(spacing: 0) {
            Text(selected.title)
                .font(.system(size: 13, weight: .semibold))
                .contentTransition(.opacity)
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
            .background(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.hairline))
            .contentShape(Rectangle())
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

private struct ModuleDock: View {
    let modules: [ModuleInfo]
    let selectedID: String
    let namespace: Namespace.ID
    let select: (String) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(modules.enumerated()), id: \.element.id) { index, module in
                let isSelected = module.id == selectedID
                Button {
                    select(module.id)
                } label: {
                    Image(systemName: module.symbol)
                        .symbolVariant(isSelected ? .fill : .none)
                        .font(.system(size: 13, weight: .semibold))
                        .matchedGeometryEffect(id: "icon-\(module.id)", in: namespace)
                        .frame(width: 38, height: 30)
                        .foregroundStyle(isSelected ? Theme.ink : Theme.tertiaryInk)
                        .background {
                            if isSelected {
                                Capsule()
                                    .fill(Theme.selection)
                                    .matchedGeometryEffect(id: "dock-highlight", in: namespace)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(index < 9 ? "\(module.title)  ⌘\(index + 1)" : module.title)
                .accessibilityLabel(module.title)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(4)
        .background(Theme.fill, in: Capsule())
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
    let activity: LiveActivity
    let notchSize: CGSize
    let waiting: Int
    let namespace: Namespace.ID

    var body: some View {
        HStack(spacing: 0) {
            leading
                .matchedGeometryEffect(id: "icon-\(activity.moduleID)", in: namespace)
                .padding(.leading, 12)
                .frame(width: activity.earWidth, alignment: .leading)

            Color.clear
                .frame(width: notchSize.width)

            trailing
                .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .padding(.trailing, 12)
                .frame(width: activity.earWidth, alignment: .trailing)
                .overlay(alignment: .trailing) {
                    if waiting > 0 {
                        WaitingDots(count: waiting)
                            .padding(.trailing, 4)
                            .transition(.opacity)
                    }
                }
        }
        .frame(height: notchSize.height)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var leading: some View {
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
                Image(systemName: activity.symbol)
                    .font(.system(size: activity.progress == nil ? 13 : 10, weight: .semibold))
                    .foregroundStyle(activity.tint)
                    .popOnChange(of: activity.id)
            }
            .frame(width: 26, height: 26)
        }
    }

    @ViewBuilder private var trailing: some View {
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
                .frame(width: 20, height: 14)
        case .level(let value):
            LevelBar(value: value, tint: activity.tint)
                .frame(width: max(activity.earWidth - 30, 30))
        case .ticker(let lines):
            TickerText(lines: lines)
        }
    }
}

/// Four bars that bounce while music plays. Core Animation runs them in the
/// window server, so they cost Xotch almost nothing even over hours of music.
private struct EqualizerBars: View {
    let tint: Color
    @Environment(\.snapshotMode) private var snapshotMode

    var body: some View {
        Group {
            if snapshotMode || Motion.reduceMotion {
                HStack(spacing: 2) {
                    ForEach([0.5, 0.9, 0.35, 0.7], id: \.self) { height in
                        Capsule().fill(tint).frame(width: 3, height: 14 * height)
                    }
                }
            } else {
                EqualizerLayers(tint: NSColor(tint))
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Playing")
    }
}

private struct EqualizerLayers: NSViewRepresentable {
    let tint: NSColor

    func makeNSView(context: Context) -> EqualizerView {
        EqualizerView()
    }

    func updateNSView(_ view: EqualizerView, context: Context) {
        view.tint = tint
    }
}

/// Bars that follow the music when real audio levels are on (see AudioLevels),
/// and bounce by themselves otherwise.
final class EqualizerView: NSView {
    private static let durations: [CFTimeInterval] = [0.42, 0.55, 0.37, 0.49]
    private static let offsets: [CFTimeInterval] = [0, 0.12, 0.25, 0.06]
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

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for _ in 0..<4 {
            let bar = CALayer()
            bar.cornerRadius = 1.5
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
            bar.bounds = CGRect(x: 0, y: 0, width: 3, height: bounds.height)
            bar.position = CGPoint(x: CGFloat(index) * 5 + 1.5, y: bounds.midY)
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
        guard window != nil, AudioLevels.shared.isEnabled else { return }
        AudioLevels.shared.acquire()
        isAcquired = true
        // 20 updates a second, only while the bars are on screen.
        let timer = Timer(timeInterval: 0.05, repeats: true) { @Sendable [weak self] _ in
            MainActor.assumeIsolated { self?.followLevels() }
        }
        timer.tolerance = 0.01
        RunLoop.main.add(timer, forMode: .common)
        levelTimer = timer
    }

    private func followLevels() {
        guard let levels = AudioLevels.shared.current() else {
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
        for (index, bar) in bars.enumerated() where bar.animation(forKey: "bounce") == nil {
            let bounce = CABasicAnimation(keyPath: "transform.scale.y")
            bounce.fromValue = 0.25
            bounce.toValue = 1.0
            bounce.duration = Self.durations[index]
            bounce.autoreverses = true
            bounce.repeatCount = .infinity
            bounce.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            bounce.beginTime = CACurrentMediaTime() + Self.offsets[index]
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
