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

                Circle()
                    .fill(.white)
                    .frame(width: 40, height: 40)
                    .shadow(color: .black.opacity(0.3), radius: 6, y: 2)
                    .overlay(
                        Image(systemName: "arrow.left.and.right")
                            .font(.footnote.weight(.bold))
                            .foregroundStyle(.black)
                    )
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
                        if (newPosition == 0 || newPosition == 1), newPosition != position { Haptics.tap() }
                        position = newPosition
                    }
                    .onEnded { _ in axis = nil }
            )
            .onTapGesture(count: 1, coordinateSpace: .local) { location in
                guard width > 0 else { return }
                Haptics.tap()
                withAnimation(Theme.spring) { position = min(max(location.x / width, 0), 1) }
            }
        }
        .aspectRatio(aspectRatio, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
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
            .font(.caption.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.black.opacity(0.4), in: Capsule())
            .padding(10)
    }
}
