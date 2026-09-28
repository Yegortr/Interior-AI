import SwiftUI

/// Apple-style welcome sheet (like the first launch of Freeform or Journal): a title, three
/// feature rows with SF Symbols, and one Continue button. Shown once, over the gallery.
struct OnboardingView: View {
    let onFinish: () -> Void

    @State private var appeared = false

    private struct Feature: Identifiable {
        let symbol: String
        let color: Color
        let title: String
        let text: String
        var id: String { title }
    }

    private let features = [
        Feature(symbol: "camera.viewfinder", color: .blue, title: "Snap Your Space",
                text: "Take a photo of any room, balcony, yard or garden."),
        Feature(symbol: "wand.and.sparkles", color: .purple, title: "Pick a Style",
                text: "See it redesigned in seconds, then refine it with Make Changes."),
        Feature(symbol: "leaf.fill", color: .green, title: "Plants for Your Climate",
                text: "For gardens, get plants that thrive where you live, with care tips."),
    ]

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 40) {
                    VStack(spacing: 12) {
                        Image(systemName: "sofa.fill")
                            .font(.system(size: 64))
                            .foregroundStyle(.tint)
                            .symbolEffect(.bounce, value: appeared)
                        Text("Welcome to Reroom")
                            .font(.largeTitle.bold())
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, 48)

                    VStack(alignment: .leading, spacing: 28) {
                        ForEach(Array(features.enumerated()), id: \.element.id) { index, feature in
                            HStack(alignment: .top, spacing: 16) {
                                Image(systemName: feature.symbol)
                                    .font(.title)
                                    .foregroundStyle(feature.color)
                                    .frame(width: 44)
                                    .symbolEffect(.bounce, value: appeared)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(feature.title).font(.headline)
                                    Text(feature.text).font(.subheadline).foregroundStyle(.secondary)
                                }
                            }
                            .opacity(appeared ? 1 : 0)
                            .offset(y: appeared ? 0 : 12)
                            .animation(.smooth.delay(0.1 * Double(index + 1)), value: appeared)
                        }
                    }
                    .padding(.horizontal, 32)
                }
            }

            VStack(spacing: 12) {
                Text("No account needed. Your designs stay on your devices and in your iCloud.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button(action: onFinish) {
                    Text("Continue")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 24)
        }
        .onAppear { appeared = true }
    }
}
