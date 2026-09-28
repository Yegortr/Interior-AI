import SwiftUI

/// Drag the divider to reveal the original ("Before") over the AI design ("After").
/// The drag axis-locks: vertical drags fall through to the enclosing scroll view / sheet.
struct BeforeAfterSlider: View {
    let before: UIImage
    let after: UIImage
    let aspectRatio: CGFloat

    @State private var position: CGFloat = 0.5
    @State private var axis: Axis?
    @State private var dragStartPosition: CGFloat = 0.5

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let dividerX = width * position

            ZStack(alignment: .leading) {
                Image(uiImage: after)
                    .resizable()
                    .scaledToFill()
                    .frame(width: width, height: proxy.size.height)
                    .clipped()

                Image(uiImage: before)
                    .resizable()
                    .scaledToFill()
                    .frame(width: width, height: proxy.size.height)
                    .clipped()
                    .mask(alignment: .leading) {
                        Rectangle().frame(width: dividerX)
                    }

                label("Before")
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .opacity(position > 0.12 ? 1 : 0)
                label("After")
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .opacity(position < 0.88 ? 1 : 0)

                Rectangle()
                    .fill(.white)
                    .frame(width: 3)
                    .shadow(color: .black.opacity(0.35), radius: 3)
                    .offset(x: dividerX - 1.5)

                Image(systemName: "arrow.left.and.right")
                    .font(.footnote.weight(.bold))
                    .frame(width: 40, height: 40)
                    .background(.regularMaterial, in: Circle())
                    .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
                    .offset(x: dividerX - 20)
            }
            .contentShape(Rectangle())
            .simultaneousGesture(
                DragGesture(minimumDistance: 6)
                    .onChanged { value in
                        if axis == nil {
                            axis = abs(value.translation.width) > abs(value.translation.height) ? .horizontal : .vertical
                            dragStartPosition = position
                        }
                        guard axis == .horizontal, width > 0 else { return }
                        let newPosition = min(max(dragStartPosition + value.translation.width / width, 0), 1)
                        position = newPosition
                    }
                    .onEnded { _ in axis = nil }
            )
            .onTapGesture(count: 1, coordinateSpace: .local) { location in
                guard width > 0 else { return }
                withAnimation(.snappy) { position = min(max(location.x / width, 0), 1) }
            }
        }
        .aspectRatio(aspectRatio, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .sensoryFeedback(.impact(weight: .light), trigger: position == 0 || position == 1) { _, atEdge in atEdge }
        .accessibilityElement()
        .accessibilityLabel("Before and after comparison")
        .accessibilityValue("\(Int(position * 100)) percent original")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: position = min(1, position + 0.1)
            case .decrement: position = max(0, position - 0.1)
            @unknown default: break
            }
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.thinMaterial, in: Capsule())
            .padding(10)
    }
}
