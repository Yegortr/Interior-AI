import SwiftData
import SwiftUI

struct SettingsView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var designs: [Design]
    @AppStorage("gallery.columnCount") private var columnCount = 2
    @State private var confirmDeleteAll = false

    private var iCloudAvailable: Bool { FileManager.default.ubiquityIdentityToken != nil }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(iCloudAvailable ? "iCloud sync is on" : "Stored on this iPhone only")
                            Text(iCloudAvailable
                                 ? "Your designs sync to your other devices through your private iCloud."
                                 : "Sign in to iCloud in Settings to sync and back up your designs.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: iCloudAvailable ? "icloud.fill" : "icloud.slash")
                            .foregroundStyle(iCloudAvailable ? Color.accentColor : .secondary)
                    }
                    LabeledContent("Designs", value: "\(designs.count)")
                } header: {
                    Text("Your designs")
                }

                Section("Gallery") {
                    Picker("Layout", selection: $columnCount) {
                        Text("1 column").tag(1)
                        Text("2 columns").tag(2)
                    }
                }

                Section {
                    Button("Delete All Designs", role: .destructive) { confirmDeleteAll = true }
                        .disabled(designs.isEmpty)
                } footer: {
                    Text("Reroom has no accounts. Photos are sent to our server only while a design is being generated.")
                }

                Section {
                    LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")
                    if !AppConfig.isConfigured {
                        Label("Server not configured (see README)", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .confirmationDialog("Delete all designs?", isPresented: $confirmDeleteAll, titleVisibility: .visible) {
                Button("Delete All", role: .destructive) {
                    for design in designs { context.delete(design) }
                    try? context.save()
                    Haptics.success()
                }
            } message: {
                Text("This removes them from this iPhone and from iCloud. It can't be undone.")
            }
        }
    }
}
