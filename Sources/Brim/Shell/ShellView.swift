import SwiftUI

/// The root view inside the notch panel: one black shape whose size and
/// content follow the model's phase.
struct ShellView: View {
    let model: NotchViewModel
    let actions: any NotchActions

    @AppStorage(SettingsKey.moduleOrder) private var moduleOrder = ""
    @AppStorage(SettingsKey.hiddenModules) private var hiddenModules = ""
    @Namespace private var namespace

    var body: some View {
        let shape = NotchShape(shoulderRadius: model.shoulder, cornerRadius: model.cornerRadius)
        let size = model.bodySize
        let width = size.width + model.shoulder * 2
        let modules = ModuleRegistry.visible(order: moduleOrder, hidden: hiddenModules)

        ZStack(alignment: .top) {
            shape
                .fill(Theme.notch)
                .shadow(color: .black.opacity(model.phase == .open ? 0.45 : 0), radius: 22, y: 10)

            ZStack(alignment: .top) {
                if model.showsActivity, let activity = model.activities.current {
                    LiveActivityBar(activity: activity,
                                    notchSize: model.closedSize,
                                    namespace: namespace)
                        .transition(.blurFade)
                }
                if model.phase == .open {
                    OpenContent(model: model, modules: modules, actions: actions, namespace: namespace)
                        .frame(width: Layout.openSize.width, height: Layout.openSize.height, alignment: .top)
                        .transition(.blurScale)
                }
            }
            .padding(.horizontal, model.shoulder)
            .frame(width: width, height: size.height, alignment: .top)
            .clipShape(shape)
        }
        .frame(width: width, height: size.height)
        .contentShape(shape)
        .onTapGesture { actions.tapped() }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
    }
}

// MARK: - Open state

private struct OpenContent: View {
    let model: NotchViewModel
    let modules: [any NotchModule]
    let actions: any NotchActions
    let namespace: Namespace.ID

    private var selected: (any NotchModule)? {
        modules.first { $0.id == model.selectedModuleID } ?? modules.first
    }

    var body: some View {
        VStack(spacing: 0) {
            topRow
                .frame(height: model.closedSize.height)

            ZStack(alignment: .topLeading) {
                if let selected {
                    selected.expandedView()
                        .id(selected.id)
                        .transition(.push(from: model.switchEdge))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 24)
            .padding(.top, 16)
            .padding(.bottom, 22)
            .clipped()
        }
        .foregroundStyle(Theme.ink)
    }

    /// Tabs on the left of the camera housing, title and pin on the right.
    private var topRow: some View {
        HStack(spacing: 0) {
            ModuleSwitcher(modules: modules.map { $0.info },
                           selectedID: selected?.id ?? "",
                           namespace: namespace) { actions.select(moduleID: $0) }
                .frame(maxWidth: .infinity, alignment: .leading)

            Color.clear
                .frame(width: model.closedSize.width)

            HStack(spacing: 8) {
                Text(selected?.title ?? "")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.secondaryInk)
                    .contentTransition(.opacity)
                    .padding(.leading, 12)
                Spacer(minLength: 0)
                PinButton(isPinned: model.isPinned) { actions.togglePin() }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 14)
    }
}

private struct ModuleSwitcher: View {
    let modules: [ModuleInfo]
    let selectedID: String
    let namespace: Namespace.ID
    let select: (String) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(modules.enumerated()), id: \.element.id) { index, module in
                let isSelected = module.id == selectedID
                Button {
                    select(module.id)
                } label: {
                    Image(systemName: module.symbol)
                        .font(.system(size: 12, weight: .semibold))
                        .matchedGeometryEffect(id: "icon-\(module.id)", in: namespace)
                        .frame(width: 30, height: 22)
                        .foregroundStyle(isSelected ? Theme.ink : Theme.tertiaryInk)
                        .background {
                            if isSelected {
                                Capsule()
                                    .fill(Theme.selection)
                                    .matchedGeometryEffect(id: "tab-highlight", in: namespace)
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
            Image(systemName: activity.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(activity.tint)
                .symbolEffect(.bounce, value: activity.id)
                .matchedGeometryEffect(id: "icon-\(activity.moduleID)", in: namespace)
                .padding(.leading, 12)
                .frame(width: Layout.earWidth, alignment: .leading)

            Color.clear
                .frame(width: notchSize.width)

            Text(activity.text)
                .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Theme.ink)
                .contentTransition(.numericText())
                .lineLimit(1)
                .padding(.trailing, 12)
                .frame(width: Layout.earWidth, alignment: .trailing)
        }
        .frame(height: notchSize.height)
        .accessibilityElement(children: .combine)
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
