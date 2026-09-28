import SwiftUI

/// One questionnaire step: a native grouped `Form` pushed onto the flow's `NavigationStack`
/// (so Back and the swipe-back gesture are the system ones), a progress bar in the nav bar and a
/// pinned prominent button.
struct FlowStep<Content: View>: View {
    let index: Int
    let count: Int
    let title: String
    let buttonTitle: String
    var buttonSymbol: String?
    let canContinue: Bool
    let action: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        Form {
            content()
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .principal) {
                ProgressView(value: Double(index + 1), total: Double(count))
                    .frame(width: 110)
                    .accessibilityLabel("Step \(index + 1) of \(count)")
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button(action: action) {
                Group {
                    if let buttonSymbol {
                        Label(buttonTitle, systemImage: buttonSymbol)
                    } else {
                        Text(buttonTitle)
                    }
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .disabled(!canContinue)
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.bar)
        }
    }
}
