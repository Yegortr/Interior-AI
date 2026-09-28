import SwiftData
import SwiftUI

@main
struct ReroomApp: App {
    private let container: ModelContainer
    @State private var coordinator: GenerationCoordinator

    init() {
        let container = AppModelContainer.make()
        self.container = container
        _coordinator = State(initialValue: GenerationCoordinator(api: SupabaseGenerationAPI(), context: container.mainContext))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(coordinator)
        }
        .modelContainer(container)
    }
}

enum AppModelContainer {
    /// iCloud-synced store when the build has the CloudKit entitlement and the user is signed in
    /// to iCloud; otherwise a local store. Falls back to memory so the app always launches.
    static func make() -> ModelContainer {
        let schema = Schema([Design.self])
        let candidates = [
            ModelConfiguration(schema: schema, cloudKitDatabase: .automatic),
            ModelConfiguration(schema: schema, cloudKitDatabase: .none),
        ]
        for configuration in candidates {
            if let container = try? ModelContainer(for: schema, configurations: configuration) { return container }
        }
        // swiftlint:disable:next force_try
        return try! ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
    }
}

struct RootView: View {
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @Environment(GenerationCoordinator.self) private var coordinator
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            if hasCompletedOnboarding {
                GalleryView()
                    .transition(.opacity)
            } else {
                OnboardingView {
                    withAnimation(Theme.spring) { hasCompletedOnboarding = true }
                }
                .transition(.opacity)
            }
        }
        .task {
            Haptics.prepare()
            coordinator.resume()
            // Create the invisible anonymous account early so the first generation is instant.
            if AppConfig.isConfigured { _ = try? await AnonymousAuth.userId() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await coordinator.refreshNow() } }
        }
    }
}
