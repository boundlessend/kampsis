import AppKit
import SwiftUI

enum SceneID {
    static let effect = "effect"
    static let general = "general"
}

@main struct LidfoldApp: App {
    @NSApplicationDelegateAdaptor(LaunchDelegate.self) private var launch
    private let controller = EffectController.shared

    var body: some Scene {
        Window(AppIdentity.name, id: SceneID.effect) {
            EffectWindow(state: controller.state, controller: controller)
                .frame(width: 860, height: 640)
                .onExitCommand { controller.endDemo() }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Проверить обновления…") { controller.updates.checkFromMenu() }
                    .disabled(controller.updates.checking)
            }
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .appSettings) {
                OpenSceneButton(title: "Настройки…", scene: SceneID.general)
                    .keyboardShortcut(",", modifiers: .command)
            }
            CommandMenu("Эффект") {
                Button(controller.state.toggleTitle) { controller.toggle() }
                    .keyboardShortcut("b", modifiers: [.command, .option])
            }
        }

        Window("Общие настройки", id: SceneID.general) {
            GeneralWindow(state: controller.state, controller: controller, updates: controller.updates)
                .frame(width: 480, height: 620)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .defaultLaunchBehavior(.suppressed)

        MenuBarExtra(AppIdentity.name, systemImage: controller.state.settings.isOn ? "macbook" : "pause.circle") {
            StatusMenu(state: controller.state, controller: controller)
        }
        .menuBarExtraStyle(.menu)
    }
}

@MainActor final class LaunchDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // в роли хоста тестов приложение не трогает датчик, экран и сеть
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        EffectController.shared.start()
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

/// кнопка, которая открывает окно приложения и выводит его вперёд
struct OpenSceneButton: View {
    let title: String
    let scene: String
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(title) {
            openWindow(id: scene)
            NSApp.activate()
        }
    }
}

private struct StatusMenu: View {
    let state: AppState
    let controller: EffectController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text("\(AppIdentity.name): \(state.measuredAngle.map { "\(Int($0))°" } ?? "угол неизвестен")")
        Text(state.statusLine)
        Divider()
        if !state.demoRunning {
            Button("\(state.toggleTitle)   ⌘⌥B") { controller.toggle() }
        }
        OpenSceneButton(title: "Настроить эффект…", scene: SceneID.effect)
        OpenSceneButton(title: "Общие настройки…", scene: SceneID.general)
        Button(state.demoRunning ? "Остановить демонстрацию   ⌘⌥B" : "Показать демонстрацию") {
            if state.demoRunning {
                controller.endDemo()
            } else {
                openWindow(id: SceneID.effect)
                NSApp.activate()
                controller.beginDemo()
            }
        }
        .disabled(!state.screenAccess)
        Divider()
        Button("Проверить обновления…") { controller.updates.checkFromMenu() }
            .disabled(controller.updates.checking)
        Button("Завершить \(AppIdentity.name)") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
