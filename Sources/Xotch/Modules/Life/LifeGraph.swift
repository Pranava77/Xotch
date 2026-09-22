import SwiftUI

/// A year of days as squares, darkest where you got the most done. Drawn in
/// one `Canvas` pass, so a year of history costs a single draw.
struct LifeGraph: View {
    let columns: [[Date]]
    let commits: (Date) -> Int
    @Binding var selected: Date?
    var tint: Color = Theme.accent

    /// Square size. The caller sizes it to the room it has, so the year fills
    /// the notch instead of hugging its left edge.
    var cell: CGFloat = Self.smallestCell

    @State private var hovered: Date?
    @Environment(\.snapshotMode) private var snapshotMode

    static let gap: CGFloat = 2.5
    static let smallestCell: CGFloat = 9
    private static let largestCell: CGFloat = 14
    /// Everything above the squares: the caption row, its spacing, the months.
    private static let chrome: CGFloat = 12 + 3 + 11

    /// The biggest square that fits a year of weeks in `width`.
    static func cell(fitting width: CGFloat, columns: Int) -> CGFloat {
        guard width > 0, columns > 0 else { return smallestCell }
        return min(max(width / CGFloat(columns) - gap, smallestCell), largestCell)
    }

    /// How tall the graph draws at that square size.
    static func height(cell: CGFloat) -> CGFloat { chrome + 7 * (cell + gap) }

    private var gap: CGFloat { Self.gap }
    private var step: CGFloat { cell + gap }
    private var width: CGFloat { CGFloat(columns.count) * step }
    private var height: CGFloat { 7 * step }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .bottom, spacing: 8) {
                Text(caption)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(hovered == nil && selected == nil ? Theme.tertiaryInk : Theme.ink)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Legend(tint: tint, cell: cell)
            }
            .frame(height: 12)

            ZStack(alignment: .topLeading) {
                months
                    .frame(height: 10)
                    .offset(y: -1)
                squares
                    .offset(y: 11)
            }
            .frame(width: width, height: height + 11, alignment: .topLeading)
        }
        .accessibilityElement()
        .accessibilityLabel("Commit graph")
        .accessibilityValue(caption)
    }

    private var caption: String {
        if let day = hovered ?? selected {
            let count = commits(on: day)
            return "\(count == 1 ? "1 commit" : "\(count) commits") · \(Self.dayFormatter.string(from: day))"
        }
        let total = columns.flatMap { $0 }.reduce(0) { $0 + commits($1) }
        return "\(total) commits in the last year"
    }

    private func commits(on day: Date) -> Int { commits(day) }

    private var months: some View {
        Canvas { context, _ in
            var lastMonth = -1
            for (index, week) in columns.enumerated() {
                guard let first = week.first else { continue }
                let month = LifeService.calendar.component(.month, from: first)
                let day = LifeService.calendar.component(.day, from: first)
                // Label the column where a month starts, with room to breathe.
                if month != lastMonth, day <= 7, index < columns.count - 1 {
                    lastMonth = month
                    let text = Text(Self.monthFormatter.string(from: first))
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Theme.tertiaryInk)
                    context.draw(text, at: CGPoint(x: CGFloat(index) * step, y: 5), anchor: .leading)
                }
            }
        }
    }

    private var squares: some View {
        Canvas { context, _ in
            let today = LifeService.today
            for (column, week) in columns.enumerated() {
                for (row, day) in week.enumerated() {
                    guard day <= today else { continue }
                    let rect = CGRect(x: CGFloat(column) * step, y: CGFloat(row) * step, width: cell, height: cell)
                    let path = Path(roundedRect: rect, cornerRadius: 2)
                    context.fill(path, with: .color(shade(for: commits(day))))
                    if day == selected || day == hovered {
                        context.stroke(path, with: .color(Theme.ink.opacity(0.9)), lineWidth: 1)
                    } else if day == today {
                        context.stroke(path, with: .color(Theme.ink.opacity(0.45)), lineWidth: 1)
                    }
                }
            }
        }
        .frame(width: width, height: height)
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            guard !snapshotMode else { return }
            switch phase {
            case .active(let point): hovered = day(at: point)
            case .ended: hovered = nil
            }
        }
        .onTapGesture { point in
            guard let day = day(at: point) else { return }
            withAnimation(Motion.switchModule) {
                selected = selected == day ? nil : day
            }
            Haptics.tick()
        }
    }

    private func day(at point: CGPoint) -> Date? {
        let column = Int(point.x / step), row = Int(point.y / step)
        guard columns.indices.contains(column), (0..<7).contains(row) else { return nil }
        let day = columns[column][row]
        return day <= LifeService.today ? day : nil
    }

    /// Five steps from the notch's own fill to full accent, like a heat map.
    private func shade(for commits: Int) -> Color {
        switch LifeScore.level(of: commits) {
        case 0: Theme.ink.opacity(0.08)
        case 1: tint.opacity(0.3)
        case 2: tint.opacity(0.5)
        case 3: tint.opacity(0.75)
        default: tint
        }
    }

    private struct Legend: View {
        let tint: Color
        let cell: CGFloat

        var body: some View {
            HStack(spacing: 3) {
                Text("Less")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.tertiaryInk)
                ForEach(0..<5, id: \.self) { level in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(level == 0 ? Theme.ink.opacity(0.08)
                              : tint.opacity([0, 0.3, 0.5, 0.75, 1][level]))
                        .frame(width: cell, height: cell)
                }
                Text("More")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.tertiaryInk)
            }
            .accessibilityHidden(true)
        }
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE d MMM"
        return formatter
    }()

    private static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM"
        return formatter
    }()
}

/// What you finished on the day you clicked in the graph.
struct LifeDayPanel: View {
    static let width: CGFloat = 230

    let day: Date
    let close: () -> Void
    private var life: LifeService { .shared }

    var body: some View {
        let done = life.done(on: day)
        let total = life.commits(on: day)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                SectionLabel(Self.formatter.string(from: day))
                Spacer(minLength: 4)
                Text(total == 1 ? "1 commit" : "\(total) commits")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.secondaryInk)
                Button(action: close) { Image(systemName: "xmark") }
                    .buttonStyle(IconButtonStyle(size: 18))
                    .help("Back to today")
            }
            if total == 0 {
                Text("Nothing committed that day.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiaryInk)
            } else {
                NotchScroll {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(done.milestones, id: \.1.id) { arc, milestone in
                            row(symbol: "flag.checkered", text: milestone.title, tint: arc.colour.color)
                        }
                        ForEach(done.checkIns, id: \.1.id) { arc, habit in
                            row(symbol: "circle.fill", text: habit.title, tint: arc.colour.color)
                        }
                        ForEach(done.tasks) { task in
                            row(symbol: "checkmark", text: task.title,
                                tint: life.arc(id: task.arcID)?.colour.color ?? Theme.secondaryInk)
                        }
                    }
                }
            }
        }
        .frame(width: LifeDayPanel.width, alignment: .leading)
    }

    private func row(symbol: String, text: String, tint: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 10)
            Text(text)
                .font(.system(size: 11))
                .lineLimit(1)
        }
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE d MMMM"
        return formatter
    }()
}
