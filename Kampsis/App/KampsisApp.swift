import AppKit
import Carbon
import SwiftUI

enum SceneID {
    static let effect = "effect"
    static let general = "general"
}

@main struct KampsisApp: App {
    @NSApplicationDelegateAdaptor(LaunchDelegate.self) private var launch
    private let controller: EffectController

    init() {
        // проверка Automation завершается до создания сцен и не открывает Terminal при отказе
        if ProcessInfo.processInfo.arguments.contains("--terminal-automation-check") {
            print(CaptureLaunch.terminalAuthorization(request: true))
            exit(0)
        }
        guard let domain = Bundle.main.bundleIdentifier else {
            preconditionFailure("у приложения нет bundle identifier")
        }
        prepareAppLanguage(in: .standard, domain: domain)
        controller = EffectController.shared
    }

    var body: some Scene {
        Window(AppIdentity.name, id: SceneID.effect) {
            EffectWindow(state: controller.state, controller: controller)
                .frame(minWidth: 740, minHeight: 520)
                .onExitCommand { controller.endDemo() }
                .modifier(SettingsReopenAccess(state: controller.state, delegate: launch))
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 860, height: 640)
        .commands { WindowCommands(controller: controller, delegate: launch) }

        Window("General Settings", id: SceneID.general) {
            GeneralWindow(state: controller.state, controller: controller, updates: controller.updates)
                .frame(width: 560, height: 620)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .defaultLaunchBehavior(.suppressed)
    }
}

/// команды сцены устанавливаются и при фоновом запуске, когда ни одно окно ещё не появилось
private struct WindowCommands: Commands {
    let controller: EffectController
    let delegate: LaunchDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        let _ = delegate.installWindowAction(openWindow)
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { controller.updates.checkFromMenu() }
                .disabled(controller.updates.checking)
        }
        CommandGroup(replacing: .newItem) {}
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { delegate.openWindow?(SceneID.general) }
                .keyboardShortcut(",", modifiers: .command)
        }
        CommandMenu("Effect") {
            Button { controller.toggle() } label: {
                Text(verbatim: "\(controller.state.toggleTitle)   \(shortcutLabel(controller.state.settings.toggleShortcut))")
            }
        }
    }
}

@MainActor final class LaunchDelegate: NSObject, NSApplicationDelegate {
    var openWindow: ((String) -> Void)?
    private var menuBar: MenuBarController?
    private(set) var launchedAtLogin = false
    private var initialWindowSetupFinished = false
    private var launchTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // в роли хоста тестов приложение не трогает датчик, экран и сеть
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        launchedAtLogin = isLoginLaunch(NSAppleEventManager.shared().currentAppleEvent)
            || ProcessInfo.processInfo.arguments.contains("--background-launch")
        let state = EffectController.shared.state
        state.onCaptureIndicatorChange = { [weak self] shown in self?.changeCaptureIndicator(shown) }
        state.onCaptureRouteChange = { [weak self] in self?.restartForCaptureRoute(previousIndicator: nil) }
        if !ProcessInfo.processInfo.arguments.contains("--launch-parent"), !state.wantsTerminalCapture,
           !CaptureLaunch.isTerminalSession {
            if ProcessInfo.processInfo.arguments.contains("--capture-check") {
                Task { exit(await runCaptureCheck()) }
            } else {
                startApplication()
            }
            return
        }
        launchTask = Task {
            do { try await CaptureLaunch.completeHandoff() }
            catch {
                if error is CaptureLaunchFailure {
                    NSApp.terminate(nil)
                    return
                }
                let alert = NSAlert()
                alert.messageText = String(localized: "Kampsis couldn’t restart")
                alert.informativeText = error.localizedDescription
                alert.runModal()
                NSApp.terminate(nil)
                return
            }
            if ProcessInfo.processInfo.arguments.contains("--capture-check") {
                exit(await runCaptureCheck())
            }
            if state.wantsTerminalCapture != CaptureLaunch.isTerminalSession {
                state.captureLaunchPending = true
                do {
                    let route: CaptureLaunchRoute = state.wantsTerminalCapture ? .terminal : .application
                    try await CaptureLaunch.restart(via: route, background: launchedAtLogin, releaseResources: {})
                    NSApp.terminate(nil)
                    return
                } catch {
                    state.captureLaunchPending = false
                    let alert = NSAlert()
                    alert.messageText = String(localized: "Kampsis couldn’t change the launch method")
                    alert.informativeText = error.localizedDescription
                    if CaptureLaunch.isTerminalSession {
                        alert.addButton(withTitle: String(localized: "Quit"))
                        alert.runModal()
                        NSApp.terminate(nil)
                        return
                    }
                    alert.addButton(withTitle: String(localized: "Open Normally"))
                    alert.addButton(withTitle: String(localized: "Quit"))
                    guard alert.runModal() == .alertFirstButtonReturn else {
                        NSApp.terminate(nil)
                        return
                    }
                    state.showsCaptureIndicator = true
                }
            }
            startApplication()
            do { try CaptureLaunch.confirmStarted() }
            catch {
                // родитель показывает ошибку; запоздалый ребёнок не оставляет второе модальное окно
                NSApp.terminate(nil)
            }
        }
    }

    /// запускает эффект только после передачи управления новому экземпляру
    private func startApplication() {
        let controller = EffectController.shared
        if CaptureLaunch.isTerminalSession, !CGPreflightScreenCaptureAccess() {
            if !CGRequestScreenCaptureAccess() { controller.openScreenCaptureSettings() }
        }
        controller.state.onDockIconChange = { [weak self] shown in self?.applyDockVisibility(shown) }
        applyDockVisibility(controller.state.showsDockIcon)
        controller.start(background: launchedAtLogin)
        menuBar = MenuBarController(controller: controller)
        menuBar?.openWindow = { [weak self] scene in self?.openWindow?(scene) }
        if launchedAtLogin {
            NSApp.windows.filter { $0.title == AppIdentity.name }.forEach { $0.orderOut(nil) }
        } else {
            NSApp.activate()
        }
    }

    /// изменение способа запуска вступает в силу сразу после подтверждённого перезапуска
    private func changeCaptureIndicator(_ shown: Bool) {
        let controller = EffectController.shared
        let state = controller.state
        guard shown != state.showsCaptureIndicator, !state.captureLaunchPending else { return }
        let previous = state.showsCaptureIndicator
        state.showsCaptureIndicator = shown
        restartForCaptureRoute(previousIndicator: previous)
    }

    private func restartForCaptureRoute(previousIndicator: Bool?) {
        let controller = EffectController.shared
        let state = controller.state
        guard state.wantsTerminalCapture != state.usesTerminalCapture, !state.captureLaunchPending else { return }
        state.captureLaunchProblem = nil
        state.captureLaunchPending = true
        // ребёнок должен прочитать включённость до демо, а не временное включение ради демонстрации
        controller.endDemo()
        launchTask = Task {
            do {
                let route: CaptureLaunchRoute = state.wantsTerminalCapture ? .terminal : .application
                try await CaptureLaunch.restart(via: route, background: false) { try await controller.stop() }
                NSApp.terminate(nil)
            } catch {
                if let previousIndicator { state.showsCaptureIndicator = previousIndicator }
                state.captureLaunchPending = false
                state.captureLaunchProblem = error.localizedDescription
                controller.start()
            }
        }
    }

    /// повторное открытие из Applications возвращает настройки, даже если обе иконки скрыты
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows _: Bool) -> Bool {
        guard let openWindow else { return true }
        openWindow(SceneID.general)
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    private func applyDockVisibility(_ shown: Bool) {
        let policy: NSApplication.ActivationPolicy = shown ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
    }

    func installWindowAction(_ action: OpenWindowAction) {
        openWindow = { [weak self] scene in
            self?.launchedAtLogin = false
            self?.initialWindowSetupFinished = true
            action(id: scene)
            NSApp.activate()
        }
    }

    func finishInitialWindowSetup(state: AppState) {
        guard !initialWindowSetupFinished else { return }
        initialWindowSetupFinished = true
        if launchedAtLogin {
            NSApp.windows.filter { $0.title == AppIdentity.name }.forEach { $0.orderOut(nil) }
            launchedAtLogin = false
        } else if !state.showsDockIcon, !state.showsMenuBarIcon {
            openWindow?(SceneID.general)
        }
    }
}

/// запуск LoginItems обозначен параметром события открытия приложения
func isLoginLaunch(_ event: NSAppleEventDescriptor?) -> Bool {
    guard event?.eventID == kAEOpenApplication else { return false }
    return event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        || event?.paramDescriptor(forKeyword: keyAELaunchedAsLogInItem) != nil
}

/// сохраняет действие SwiftUI для открытия настроек после закрытия всех окон
private struct SettingsReopenAccess: ViewModifier {
    let state: AppState
    let delegate: LaunchDelegate
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onAppear {
            delegate.installWindowAction(openWindow)
            delegate.finishInitialWindowSetup(state: state)
        }
    }
}
