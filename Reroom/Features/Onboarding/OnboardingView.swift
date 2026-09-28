import SwiftUI

struct OnboardingView: View {
    let onFinish: () -> Void

    @State private var page = 0

    private struct Page {
        let symbol: String
        let title: String
        let text: String
    }

    private let pages = [
        Page(symbol: "camera.viewfinder", title: "Snap your space", text: "Take a photo of any room, balcony, yard or garden."),
        Page(symbol: "leaf", title: "Plants for your climate", text: "For gardens we pick plants that thrive where you live — with care tips for each."),
        Page(symbol: "sparkles", title: "See it redesigned", text: "Get a photorealistic redesign in seconds. Compare before and after, then refine it."),
    ]

    var body: some View {
        VStack(spacing: 24) {
            TabView(selection: $page) {
                ForEach(pages.indices, id: \.self) { index in
                    let item = pages[index]
                    VStack(spacing: 24) {
                        Image(systemName: item.symbol)
                            .font(.system(size: 72, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 180, height: 180)
                            .background(Circle().fill(Color.accentColor.opacity(0.12)))
                            .symbolEffect(.bounce, value: page == index)
                            .symbolEffect(.breathe)
                        VStack(spacing: 10) {
                            Text(item.title).font(.largeTitle.bold())
                            Text(item.text)
                                .font(.body)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 32)
                        }
                    }
                    .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))
            .sensoryFeedback(.selection, trigger: page)

            Button {
                if page < pages.count - 1 {
                    withAnimation(Theme.spring) { page += 1 }
                } else {
                    onFinish()
                }
            } label: {
                Text(page < pages.count - 1 ? "Continue" : "Get Started")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .contentTransition(.numericText())
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .padding(.horizontal, 24)
            .padding(.bottom, 12)
        }
        .background(
            LinearGradient(colors: [Color.accentColor.opacity(0.15), Color(.systemBackground)], startPoint: .top, endPoint: .center)
                .ignoresSafeArea()
        )
    }
}
