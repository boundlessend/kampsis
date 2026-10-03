import AppKit
import SwiftUI

enum SceneID {
    static let effect = "effect"
    static let general = "general"
}

@main struct KampsisApp: App {
    @NSApplicationDelegateAdaptor(LaunchDelegate.self) private var launch
    private let controller: EffectController

    init() {
        guard let domain = Bundle.main.bundleIdentifier else {
            preconditionFailure("у приложения нет bundle identifier")
        }
        prepareAppLanguage(in: .standard, domain: domain)
        controller = EffectController.shared
    }

    var body: some Scene {
        Window(AppIdentity.name, id: SceneID.effect) {
            EffectWindow(state: controller.state, controller: controller)
                .frame(width: 860, height: 640)
                .onExitCommand { controller.endDemo() }
                .modifier(SettingsReopenAccess(state: controller.state, delegate: launch))
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { controller.updates.checkFromMenu() }
                    .disabled(controller.updates.checking)
            }
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .appSettings) {
                OpenSceneButton(title: "Settings…", scene: SceneID.general)
                    .keyboardShortcut(",", modifiers: .command)
            }
            CommandMenu("Effect") {
                Button { controller.toggle() } label: {
                    Text(verbatim: "\(controller.state.toggleTitle)   \(shortcutLabel(controller.state.settings.toggleShortcut))")
                }
            }
        }

        Window("General Settings", id: SceneID.general) {
            GeneralWindow(state: controller.state, controller: controller, updates: controller.updates)
                .frame(width: 560, height: 620)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .defaultLaunchBehavior(.suppressed)
    }
}

@MainActor final class LaunchDelegate: NSObject, NSApplicationDelegate {
    var openWindow: ((String) -> Void)?
    private var menuBar: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // в роли хоста тестов приложение не трогает датчик, экран и сеть
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        if ProcessInfo.processInfo.arguments.contains("--capture-check") {
            Task { exit(await runCaptureCheck()) }
            return
        }
        let controller = EffectController.shared
        controller.state.onDockIconChange = { [weak self] shown in self?.applyDockVisibility(shown) }
        applyDockVisibility(controller.state.showsDockIcon)
        controller.start()
        menuBar = MenuBarController(controller: controller)
        menuBar?.openWindow = { [weak self] scene in self?.openWindow?(scene) }
        NSApp.activate()
    }

    /// повторное открытие из Applications возвращает настройки, даже если обе иконки скрыты
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows _: Bool) -> Bool {
        guard let openWindow else { return true }
        openWindow(SceneID.general)
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    private func applyDockVisibility(_ shown: Bool) {
        NSApp.setActivationPolicy(shown ? .regular : .accessory)
    }
}

/// сохраняет действие SwiftUI для открытия настроек после закрытия всех окон
private struct SettingsReopenAccess: ViewModifier {
    let state: AppState
    let delegate: LaunchDelegate
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onAppear {
            let openWindow = openWindow
            delegate.openWindow = { scene in
                openWindow(id: scene)
                NSApp.activate()
            }
            if !state.showsDockIcon, !state.showsMenuBarIcon {
                delegate.openWindow?(SceneID.general)
            }
        }
    }
}

/// кнопка, которая открывает окно приложения и выводит его вперёд
struct OpenSceneButton: View {
    let title: LocalizedStringKey
    let scene: String
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(title) {
            openWindow(id: scene)
            NSApp.activate()
        }
    }
}
