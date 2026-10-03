import AppKit
import Observation

/// левый клик переключает эффект, правый открывает меню; видимость и значок следуют за настройками
@MainActor final class MenuBarController: NSObject {
    var openWindow: ((String) -> Void)?
    private let controller: EffectController
    private var item: NSStatusItem?

    init(controller: EffectController) {
        self.controller = controller
        super.init()
        update()
    }

    private func update() {
        withObservationTracking {
            let state = controller.state
            if state.showsMenuBarIcon {
                if item == nil {
                    item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
                    item?.button?.target = self
                    item?.button?.action = #selector(clicked)
                    item?.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
                }
                item?.button?.image = NSImage(systemSymbolName: "macbook", accessibilityDescription: state.toggleTitle)
                item?.button?.appearsDisabled = !state.settings.isOn
                item?.button?.toolTip = String(localized: "Left-click to toggle the effect. Right-click for the menu.")
                item?.button?.setAccessibilityLabel(AppIdentity.name)
                item?.button?.setAccessibilityHelp(state.toggleTitle)
            } else if let item {
                NSStatusBar.system.removeStatusItem(item)
                self.item = nil
            }
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.update() }
        }
    }

    @objc private func clicked() {
        if NSApp.currentEvent?.type == .rightMouseUp || NSApp.currentEvent?.modifierFlags.contains(.control) == true {
            guard let item, let button = item.button else { return }
            item.menu = makeMenu()
            button.performClick(nil)
            item.menu = nil
        } else {
            controller.toggle()
        }
    }

    private func makeMenu() -> NSMenu {
        let state = controller.state
        let menu = NSMenu()
        menu.autoenablesItems = false
        let angle: String
        if let measured = state.measuredAngle {
            angle = "\(AppIdentity.name): \(Int(measured))°"
        } else {
            angle = String(localized: "\(AppIdentity.name): angle unknown")
        }
        menu.addItem(withTitle: angle, action: nil, keyEquivalent: "").isEnabled = false
        menu.addItem(withTitle: state.statusLine, action: nil, keyEquivalent: "").isEnabled = false
        menu.addItem(.separator())
        let toggle = menu.addItem(withTitle: "\(state.toggleTitle)   \(shortcutLabel(state.settings.toggleShortcut))",
                                  action: #selector(toggleEffect), keyEquivalent: "")
        toggle.target = self
        add(String(localized: "Customize Effect…"), action: #selector(customizeEffect), to: menu)
        add(String(localized: "General Settings…"), action: #selector(generalSettings), to: menu)
        if !state.demoRunning {
            let demo = add(String(localized: "Show Demo"), action: #selector(showDemo), to: menu)
            demo.isEnabled = state.screenAccess
        }
        menu.addItem(.separator())
        let updates = add(String(localized: "Check for Updates…"), action: #selector(checkUpdates), to: menu)
        updates.isEnabled = !controller.updates.checking
        let quit = add(String(localized: "Quit \(AppIdentity.name)"), action: #selector(quit), to: menu)
        quit.keyEquivalent = "q"
        return menu
    }

    @discardableResult private func add(_ title: String, action: Selector, to menu: NSMenu) -> NSMenuItem {
        let entry = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
        entry.target = self
        return entry
    }

    @objc private func toggleEffect() { controller.toggle() }
    @objc private func customizeEffect() { openWindow?(SceneID.effect) }
    @objc private func generalSettings() { openWindow?(SceneID.general) }
    @objc private func showDemo() {
        openWindow?(SceneID.effect)
        controller.beginDemo()
    }
    @objc private func checkUpdates() { controller.updates.checkFromMenu() }
    @objc private func quit() { NSApp.terminate(nil) }
}
