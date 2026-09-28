import SwiftData
import SwiftUI

struct SettingsView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var designs: [Design]
    @State private var confirmDeleteAll = false

    private var iCloudAvailable: Bool { FileManager.default.ubiquityIdentityToken != nil }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent {
                        Text(iCloudAvailable ? "On" : "Off")
                    } label: {
                        SettingsLabel("iCloud Sync", symbol: iCloudAvailable ? "icloud.fill" : "icloud.slash.fill", color: .blue)
                    }
                    LabeledContent {
                        Text("\(designs.count)")
                    } label: {
                        SettingsLabel("Designs", symbol: "photo.stack.fill", color: .orange)
                    }
                } footer: {
                    Text(iCloudAvailable
                         ? "Your designs sync privately across your devices with iCloud."
                         : "Sign in to iCloud in the Settings app to sync and back up your designs.")
                }

                Section {
                    Link(destination: URL(string: UIApplication.openSettingsURLString)!) {
                        LabeledContent {
                            Image(systemName: "arrow.up.forward").foregroundStyle(.secondary)
                        } label: {
                            SettingsLabel("Camera, Photos & Location", symbol: "hand.raised.fill", color: .gray)
                        }
                    }
                    .foregroundStyle(.primary)
                } footer: {
                    Text("Reroom has no accounts. Photos are sent to the server only while a design is being generated, and only your approximate area is used for garden plants.")
                }

                Section {
                    Button(role: .destructive) {
                        confirmDeleteAll = true
                    } label: {
                        Text("Delete All Designs")
                    }
                    .disabled(designs.isEmpty)
                }

                Section {
                    LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")
                    if !AppConfig.isConfigured {
                        Label("Server not configured", systemImage: "exclamationmark.triangle.fill")
                            .symbolRenderingMode(.multicolor)
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .sensoryFeedback(.success, trigger: designs.isEmpty) { _, isEmpty in isEmpty }
            .confirmationDialog("Delete all designs?", isPresented: $confirmDeleteAll, titleVisibility: .visible) {
                Button("Delete All", role: .destructive) {
                    for design in designs { context.delete(design) }
                    try? context.save()
                }
            } message: {
                Text("This removes them from this iPhone and from iCloud. It can't be undone.")
            }
        }
    }
}

/// iOS Settings-style row label: white glyph on a rounded colored square.
private struct SettingsLabel: View {
    let title: String
    let symbol: String
    let color: Color

    init(_ title: String, symbol: String, color: Color) {
        self.title = title
        self.symbol = symbol
        self.color = color
    }

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: symbol)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(color.gradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
    }
}
