import SwiftUI

/// Shared chrome for the multi-step garden & interior questionnaires: progress bar, animated
/// step transitions and a Back / Next bar.
struct QuestionnaireScaffold<Content: View>: View {
    let step: Int
    let stepCount: Int
    let title: String
    var subtitle: String?
    let isForward: Bool
    let canContinue: Bool
    var continueTitle = "Continue"
    var isWorking = false
    let onBack: (() -> Void)?
    let onContinue: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            StepProgressBar(step: step, count: stepCount)
                .padding(.horizontal, Theme.horizontalPadding)
                .padding(.vertical, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Step \(step + 1) of \(stepCount)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                        Text(title).font(.title2.bold())
                        if let subtitle {
                            Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    content()
                }
                .padding(Theme.horizontalPadding)
                .id(step)
                .transition(.asymmetric(
                    insertion: .move(edge: isForward ? .trailing : .leading).combined(with: .opacity),
                    removal: .move(edge: isForward ? .leading : .trailing).combined(with: .opacity)
                ))
            }
            .scrollDismissesKeyboard(.interactively)

            HStack(spacing: 12) {
                if let onBack {
                    Button {
                        Haptics.tap()
                        onBack()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.headline)
                            .frame(width: 54, height: 54)
                            .background(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous).fill(Color(.secondarySystemBackground)))
                    }
                    .buttonStyle(.pressable)
                    .accessibilityLabel("Back")
                    .transition(.move(edge: .leading).combined(with: .opacity))
                }
                Button {
                    Haptics.tap()
                    onContinue()
                } label: {
                    if isWorking {
                        ProgressView().tint(.white)
                    } else {
                        Text(continueTitle)
                    }
                }
                .buttonStyle(.primary)
                .disabled(!canContinue || isWorking)
            }
            .padding(.horizontal, Theme.horizontalPadding)
            .padding(.vertical, 10)
            .background(.bar)
            .animation(Theme.spring, value: onBack == nil)
        }
        .clipped()
    }
}
