import SwiftUI

/// поведение, доступ к экрану, состояние датчика и обновления
struct GeneralWindow: View {
    @Bindable var state: AppState
    let controller: EffectController
    let updates: UpdateChecker
    @State private var privacyShown = false

    private var sensorLine: String {
        if !state.settings.isOn || state.suspended { return String(localized: "Not in use") }
        return state.sensorReady ? String(localized: "Connected") : String(localized: "Unavailable")
    }

    var body: some View {
        Form {
            Section {
                Toggle("Click when the lid opens", isOn: $state.settings.chimeOnOpen)
                Toggle("Open at login", isOn: Binding(
                    get: { state.launchesAtLogin },
                    set: { controller.setOpensAtLogin($0) }
                ))
                LabeledContent("Turn effect on or off") {
                    ShortcutRecorder(shortcut: $state.settings.toggleShortcut)
                }
                if let shortcutProblem = state.shortcutProblem {
                    Text(shortcutProblem).foregroundStyle(.orange)
                }
            }

            Section("Screen Access") {
                LabeledContent("Screen Recording") {
                    if state.screenAccess {
                        Label("Allowed", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                    } else {
                        Label("Not allowed", systemImage: "exclamationmark.circle").foregroundStyle(.orange)
                    }
                }
                if !state.screenAccess {
                    Text("Without access, the effect can’t see the desktop. The preview works either way.")
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("Allow Access…") { controller.requestScreenAccess() }
                            .buttonStyle(.glassProminent)
                        Button("Access is on but not working?") { controller.explainAccessRecovery() }
                            .buttonStyle(.link)
                    }
                }
                DisclosureGroup("What happens to the image", isExpanded: $privacyShown) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Frames live only in this Mac’s memory and are replaced right away by the next ones. \(AppIdentity.name) doesn’t save screenshots, record audio, or send anything over the network.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Open macOS Settings") { controller.openScreenCaptureSettings() }
                            .buttonStyle(.link)
                    }
                    .padding(.top, 6)
                }
            }

            Section {
                LabeledContent("Mac Model", value: controller.sensor.modelIdentifier)
                LabeledContent("Lid Angle", value: state.measuredAngle.map { "\(Int($0))°" } ?? String(localized: "No data"))
                LabeledContent("Sensor", value: sensorLine)
                LabeledContent("Effect", value: state.statusLine)
                if let problem = state.problem {
                    Text(problem).foregroundStyle(.orange)
                }
                if state.settings.isOn, !state.suspended, !state.sensorReady {
                    Text(state.sensorNote).foregroundStyle(.secondary)
                }
                Button("Check Again") { controller.retry() }
                    .buttonStyle(.link)
            } header: {
                Text("Status")
            } footer: {
                Text("The effect appears only on the built-in display. A closed MacBook sleeps as usual.")
            }

            Section("Updates") {
                LabeledContent("Version", value: AppIdentity.version)
                Toggle("Check once a day", isOn: Binding(
                    get: { updates.checksAutomatically },
                    set: { updates.setChecksAutomatically($0) }
                ))
                Text("Release information comes from GitHub. Whether to download a new version is up to you.")
                    .foregroundStyle(.secondary)
                Button("Check for Updates…") { updates.checkFromMenu() }
                    .disabled(updates.checking)
            }
        }
        .formStyle(.grouped)
    }
}
