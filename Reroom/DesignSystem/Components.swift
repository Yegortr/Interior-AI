import SwiftUI

/// A capsule chip used for tags, multi-select options and badges.
struct Chip: View {
    let title: String
    var symbol: String?
    var isSelected = false

    var body: some View {
        HStack(spacing: 6) {
            if let symbol { Image(systemName: symbol).imageScale(.small) }
            Text(title).lineLimit(1)
        }
        .font(.subheadline.weight(.medium))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .foregroundStyle(isSelected ? Color.white : Color.primary)
        .background(
            Capsule(style: .continuous)
                .fill(isSelected ? Color.accentColor : Color(.secondarySystemBackground))
        )
        .contentShape(Capsule())
    }
}

/// A small informational badge (sun, water, care level…).
struct Badge: View {
    let title: String
    let symbol: String
    var tint: Color = .accentColor

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .foregroundStyle(tint)
            .background(Capsule().fill(tint.opacity(0.14)))
    }
}

/// Large selectable option card used by the questionnaires.
struct OptionCard: View {
    let title: String
    var subtitle: String?
    var symbol: String?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            HStack(spacing: 14) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.title3)
                        .frame(width: 36, height: 36)
                        .foregroundStyle(isSelected ? Color.white : Color.accentColor)
                        .background(Circle().fill(isSelected ? Color.accentColor : Color.accentColor.opacity(0.12)))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    if let subtitle {
                        Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.5))
                    .contentTransition(.symbolEffect(.replace))
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                    .fill(Color(.secondarySystemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .animation(Theme.snappy, value: isSelected)
    }
}

/// Wrapping horizontal layout for chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(width: bounds.width, subviews: subviews)
        for row in rows {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row {
        var indices: [Int] = []
        var y: CGFloat = 0
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        var y: CGFloat = 0
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let current = rows[rows.count - 1]
            let proposedWidth = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if proposedWidth > width, !current.indices.isEmpty {
                y += current.height + spacing
                rows.append(Row(indices: [index], y: y, width: size.width, height: size.height))
            } else {
                rows[rows.count - 1].indices.append(index)
                rows[rows.count - 1].width = proposedWidth
                rows[rows.count - 1].height = max(current.height, size.height)
            }
        }
        return rows
    }
}

/// Section title used across forms.
struct SectionHeader: View {
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.title3.weight(.semibold))
            if let subtitle {
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Animated shimmer used by loading placeholders.
struct Shimmer: ViewModifier {
    @State private var phase: CGFloat = -1

    func body(content: Content) -> some View {
        content
            .overlay {
                GeometryReader { proxy in
                    LinearGradient(
                        colors: [.clear, .white.opacity(0.18), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: proxy.size.width * 0.8)
                    .offset(x: phase * proxy.size.width * 1.4)
                }
                .allowsHitTesting(false)
            }
            .clipped()
            .onAppear {
                withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) { phase = 1 }
            }
    }
}

extension View {
    func shimmering() -> some View { modifier(Shimmer()) }
}

/// Top-of-screen progress bar for multi-step flows.
struct StepProgressBar: View {
    let step: Int
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(index <= step ? Color.accentColor : Color.secondary.opacity(0.2))
                    .frame(height: 4)
            }
        }
        .animation(Theme.spring, value: step)
        .accessibilityElement()
        .accessibilityLabel("Step \(step + 1) of \(count)")
    }
}
