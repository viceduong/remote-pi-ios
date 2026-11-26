import SwiftUI

/// Custom environment value for the chat text-size scale.
private struct ChatTextScaleKey: EnvironmentKey {
    static let defaultValue: Double = 1.0
}

extension EnvironmentValues {
    var chatTextScale: Double {
        get { self[ChatTextScaleKey.self] }
        set { self[ChatTextScaleKey.self] = newValue }
    }
}

/// Settings sheet: chat text size, theme and per-server notifications.
@MainActor
struct SettingsView: View {
    /// Configured servers — notification settings live on each server (§14).
    let servers: [ServerConfig]
    @AppStorage("chatTextScale") private var textScale: Double = 1.0
    @AppStorage("themeName") private var themeName = "darkGrey"
    @Environment(\.dismiss) private var dismiss

    init(servers: [ServerConfig] = []) {
        self.servers = servers
    }

    var body: some View {
        NavigationView {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("A").font(.system(size: 13 * textScale))
                            Slider(value: $textScale, in: 0.6...2.0, step: 0.05)
                            Text("A").font(.system(size: 20 * textScale))
                        }
                        Text(String(format: "%.0f%%", textScale * 100))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } header: {
                    Text("Chat text size")
                } footer: {
                    Text("Applies to messages, tool output and thinking blocks.")
                }

                Section {
                    Picker("Theme", selection: $themeName) {
                        HStack {
                            Circle().fill(Color(hex: 0x1E1F23)).frame(width: 14, height: 14)
                            Text("Dark grey").tag("darkGrey")
                        }
                        HStack {
                            Circle().fill(Color(hex: 0x000000)).frame(width: 14, height: 14)
                            Text("Black").tag("black")
                        }
                        HStack {
                            Circle().fill(Color(hex: 0xF4F5F7)).frame(width: 14, height: 14)
                                .overlay(Circle().stroke(Color.gray.opacity(0.5)))
                            Text("Light").tag("light")
                        }
                    }
                    .pickerStyle(.inline)
                } header: {
                    Text("Theme")
                } footer: {
                    Text("Dark grey is the default: soft grey background with light grey text.")
                }

                Section {
                    if servers.isEmpty {
                        Text("Add a server first.")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(servers) { server in
                            NavigationLink(destination: NotificationSettingsView(server: server)) {
                                Label {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(servers.count == 1 ? "Notifications" : displayName(server))
                                        if servers.count > 1 {
                                            Text(server.baseURL)
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                                .lineLimit(1)
                                        }
                                    }
                                } icon: {
                                    Image(systemName: "bell.badge")
                                }
                            }
                        }
                    }
                } header: {
                    Text("Notifications")
                } footer: {
                    Text("Push to your iPhone through the Bark app when an agent finishes a turn. "
                         + "Set up on each server.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private func displayName(_ server: ServerConfig) -> String {
        server.name.isEmpty ? server.baseURL : server.name
    }
}
