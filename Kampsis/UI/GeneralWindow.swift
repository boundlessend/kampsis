import AppKit
import SwiftUI

/// поведение, доступ к экрану, состояние датчика и обновления
struct GeneralWindow: View {
    @Bindable var state: AppState
    let controller: EffectController
    let updates: UpdateChecker
    @Environment(\.openWindow) private var openWindow
    @State private var privacyShown = false
    @State private var language: AppLanguage = Bundle.main.preferredLocalizations.first == "ru" ? .russian : .english
    @State private var diagnosticsCopied = false
    @State private var diagnosticsProblem: String?
    @State private var indicatorShown = true
    @State private var requestedIndicator: Bool?
    @State private var confirmsIndicatorChange = false
    @State private var confirmsSettingsReset = false

    private var sensorLine: String {
        if !state.settings.isOn || state.suspended { return String(localized: "Not in use") }
        return state.sensorReady ? String(localized: "Connected") : String(localized: "Unavailable")
    }

    var body: some View {
        Form {
            Section {
                Button("Customize Effect…") {
                    openWindow(id: SceneID.effect)
                    NSApp.activate()
                }
                .buttonStyle(.link)
                Picker("Language", selection: $language) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(verbatim: language.title).tag(language)
                    }
                }
                .onChange(of: language) { _, selected in
                    UserDefaults.standard.set([selected.rawValue], forKey: "AppleLanguages")
                    let alert = NSAlert()
                    alert.messageText = String(localized: "Restart to change language")
                    alert.informativeText = String(localized: "The new language will apply the next time you open Kampsis.")
                    alert.addButton(withTitle: String(localized: "Quit Now"))
                    alert.addButton(withTitle: String(localized: "Later"))
                    if alert.runModal() == .alertFirstButtonReturn { NSApp.terminate(nil) }
                }
                Toggle("Click when the lid opens", isOn: $state.settings.chimeOnOpen)
                    .disabled(state.settingsProblem != nil)
                Toggle("Show icon in Dock", isOn: $state.showsDockIcon)
                Toggle("Show icon in menu bar", isOn: $state.showsMenuBarIcon)
                Toggle("Open at login", isOn: Binding(
                    get: { state.launchesAtLogin },
                    set: { controller.setOpensAtLogin($0) }
                ))
                if state.loginNeedsApproval {
                    LabeledContent("Open at login", value: String(localized: "Awaiting approval"))
                    Button("Approve in macOS Settings…") { controller.openLoginSettings() }
                        .buttonStyle(.link)
                }
                if let loginProblem = state.loginProblem {
                    Text(loginProblem).foregroundStyle(.orange)
                }
                LabeledContent("Turn effect on or off") {
                    ShortcutRecorder(shortcut: $state.settings.toggleShortcut)
                        .disabled(state.settingsProblem != nil)
                }
                if let shortcutProblem = state.shortcutProblem {
                    Text(shortcutProblem).foregroundStyle(.orange)
                }
            }

            Section("Screen Access") {
                Picker("Desktop Image", selection: $state.captureMode) {
                    if state.captureMode == nil {
                        Text("Choose Capture Mode").tag(CaptureMode?.none)
                    }
                    ForEach(CaptureMode.allCases) { mode in
                        Text(verbatim: mode.title).tag(Optional(mode))
                    }
                }
                .accessibilityIdentifier("capture-mode")
                .disabled(state.captureLaunchPending)
                if let mode = state.captureMode {
                    Text(verbatim: mode.summary)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let problem = state.captureModeProblem {
                    Text(problem).foregroundStyle(.orange)
                }
                Toggle("Use experimental Terminal launch", isOn: Binding(
                    get: { state.captureMode == .snapshot ? false : !indicatorShown },
                    set: {
                        indicatorShown = !$0
                        requestedIndicator = !$0
                        confirmsIndicatorChange = true
                    }
                ))
                .disabled(state.captureLaunchPending || state.captureMode == .snapshot || state.captureMode == nil)
                if state.captureMode == .snapshot {
                    Text("Single Snapshot uses the normal app launch and doesn’t need Terminal permissions. macOS controls its own capture indicator.")
                        .foregroundStyle(.secondary)
                } else {
                    Text("May hide the macOS capture indicator for streams. Requires additional permissions and may leave Terminal in the Dock. Changing this option restarts Kampsis.")
                        .foregroundStyle(.secondary)
                }
                if state.captureLaunchPending {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Restarting…").foregroundStyle(.secondary)
                    }
                }
                if let problem = state.captureLaunchProblem {
                    Text(problem).foregroundStyle(.orange)
                }
                if state.usesTerminalCapture {
                    Text("Screen recording access belongs to Terminal in this mode.")
                        .foregroundStyle(.secondary)
                }
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
                    }
                }
                Button("Access is on but not working?") { controller.explainAccessRecovery() }
                    .buttonStyle(.link)
                DisclosureGroup("What happens to the image", isExpanded: $privacyShown) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Images stay in this Mac’s memory while the effect is in use. \(AppIdentity.name) doesn’t save screenshots, record audio, or send screen images over the network.")
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
                if let problem = state.settingsProblem {
                    Text(problem).foregroundStyle(.orange)
                    Button("Reset Effect Settings…") { confirmsSettingsReset = true }
                        .buttonStyle(.link)
                }
                if let pointerProblem = state.pointerProblem {
                    Text(pointerProblem).foregroundStyle(.orange)
                }
                if state.settings.isOn, !state.suspended, !state.sensorReady {
                    Text(state.sensorNote).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Check Again") { controller.retry() }
                        .buttonStyle(.link)
                    Button(diagnosticsCopied ? "Diagnostics Copied" : "Copy Diagnostics") {
                        do {
                            try controller.copyDiagnostics()
                            diagnosticsCopied = true
                            diagnosticsProblem = nil
                        } catch {
                            diagnosticsCopied = false
                            diagnosticsProblem = error.localizedDescription
                        }
                    }
                    .buttonStyle(.link)
                }
                if let diagnosticsProblem { Text(diagnosticsProblem).foregroundStyle(.orange) }
            } header: {
                Text("Status")
            } footer: {
                Text("The effect appears only on the built-in display. A closed MacBook sleeps as usual.")
            }

            Section("Updates") {
                LabeledContent("Version", value: AppIdentity.version)
                Button("Open License") {
                    if let license = Bundle.main.url(forResource: "LICENSE", withExtension: nil) { NSWorkspace.shared.open(license) }
                }
                .buttonStyle(.link)
                Toggle("Check once a day", isOn: Binding(
                    get: { updates.checksAutomatically },
                    set: { updates.setChecksAutomatically($0) }
                ))
                Text("Release information comes from GitHub. Whether to download a new version is up to you.")
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Check for Updates…") { updates.checkFromMenu() }
                        .disabled(updates.checking)
                    if updates.checking {
                        ProgressView().controlSize(.small)
                        Text("Checking…").foregroundStyle(.secondary)
                    }
                }
                if let release = updates.availableRelease {
                    Button("Open Release \(release.tagName)…") { updates.openAvailableRelease() }
                        .buttonStyle(.link)
                }
            }
        }
        .formStyle(.grouped)
        .disabled(state.captureLaunchPending)
        .onAppear {
            controller.refreshLoginStatus()
            indicatorShown = state.showsCaptureIndicator
        }
        .onChange(of: state.showsCaptureIndicator) { _, shown in indicatorShown = shown }
        .alert("Restart to change the launch method", isPresented: $confirmsIndicatorChange,
               presenting: requestedIndicator) { shown in
            Button("Restart Now") { state.onCaptureIndicatorChange?(shown) }
            Button("Cancel", role: .cancel) {
                indicatorShown = state.showsCaptureIndicator
                requestedIndicator = nil
            }
        } message: { shown in
            if shown {
                Text("Kampsis will restart using the normal app launch. macOS controls whether its capture indicator appears.")
            } else {
                Text("This experimental mode starts Kampsis through Apple Terminal. Allow Kampsis to control Terminal and allow Terminal to record the screen. This access also applies to other commands run in Terminal. Its launch window closes automatically; existing Terminal windows stay open. Terminal may remain in the Dock while Kampsis runs. A macOS update may stop this mode from hiding the indicator.")
            }
        }
        .alert("Reset unreadable effect settings?", isPresented: $confirmsSettingsReset) {
            Button("Reset Settings") { state.resetUnreadableSettings() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This replaces the unreadable effect settings with defaults. The effect stays off until you turn it on. Capture mode, language, and icon preferences stay as they are.")
        }
    }
}
