import QuartzCore
import SwiftUI

/// The root view inside the notch panel: one black shape whose size and
/// content follow the model's phase.
struct ShellView: View {
    let model: NotchViewModel
    let actions: any NotchActions

    @AppStorage(SettingsKey.moduleOrder) private var moduleOrder = ""
    @AppStorage(SettingsKey.hiddenModules) private var hiddenModules = ""
    @Namespace private var namespace
    @State private var isDropTarget = false

    var body: some View {
        let shape = NotchShape(shoulderRadius: model.shoulder, cornerRadius: model.cornerRadius)
        let size = model.bodySize
        let width = size.width + model.shoulder * 2
        let modules = ModuleRegistry.visible(order: moduleOrder, hidden: hiddenModules)
        let selected = modules.first { $0.id == model.selectedModuleID } ?? modules[0]
        let tint = model.phase == .open ? selected.tint : nil

        ZStack(alignment: .top) {
            shape
                .fill(Theme.notch)
                .shadow(color: .black.opacity(model.phase == .open ? 0.45 : 0), radius: 22, y: 10)

            ZStack(alignment: .top) {
                if let tint {
                    RadialGradient(colors: [tint.opacity(0.32), tint.opacity(0)],
                                   center: .topLeading, startRadius: 10, endRadius: 520)
                        .transition(.opacity)
                }
                if model.showsActivity, let activity = model.activities.current {
                    LiveActivityBar(activity: activity,
                                    notchSize: model.closedSize,
                                    namespace: namespace)
                        .transition(.blurFade)
                }
                if model.phase == .open {
                    OpenContent(model: model, modules: modules, selected: selected,
                                actions: actions, namespace: namespace)
                        .frame(width: Layout.openSize.width, height: Layout.openSize.height, alignment: .top)
                        .transition(.blurScale)
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
            .animation(Motion.switchModule, value: tint)
        }
        .frame(width: width, height: size.height)
        .contentShape(shape)
        .onTapGesture { actions.tapped() }
        .modifier(ShelfDropTarget(onDrop: { actions.select(moduleID: "shelf") }, isTargeted: $isDropTarget))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
    }

    /// Title left of the camera housing, pin on the right.
    private var topRow: some View {
        HStack(spacing: 0) {
            Text(selected.title)
                .font(.system(size: 13, weight: .semibold))
                .contentTransition(.opacity)
                .frame(maxWidth: .infinity, alignment: .leading)

            Color.clear
                .frame(width: model.closedSize.width)

            HStack {
                Spacer(minLength: 0)
                PinButton(isPinned: model.isPinned) { actions.togglePin() }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 22)
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
    let namespace: Namespace.ID

    var body: some View {
        HStack(spacing: 0) {
            Group {
                if let image = activity.image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 22, height: 22)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                } else {
                    Image(systemName: activity.symbol)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(activity.tint)
                        .popOnChange(of: activity.id)
                }
            }
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
        }
        .frame(height: notchSize.height)
        .accessibilityElement(children: .combine)
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
        }
    }
}

/// Four bars that bounce while music plays. Core Animation runs them in the
/// window server, so they cost Brim almost nothing even over hours of music.
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

final class EqualizerView: NSView {
    private static let durations: [CFTimeInterval] = [0.42, 0.55, 0.37, 0.49]
    private static let offsets: [CFTimeInterval] = [0, 0.12, 0.25, 0.06]
    private var bars: [CALayer] = []

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
        startAnimating()
    }

    private func startAnimating() {
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
