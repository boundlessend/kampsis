import AppKit
import CoreGraphics
import Darwin

enum PointerAction: Equatable, Sendable {
    case hide
    case show
}

/// что сделать с курсором: прячем, только пока он над эффектом, и возвращаем только спрятанный нами
func pointerAction(hiddenByUs: Bool, overEffect: Bool) -> PointerAction? {
    switch (hiddenByUs, overEffect) {
    case (false, true): .hide
    case (true, false): .show
    default: nil
    }
}

/// коннектор к курсору: над оверлеем курсор не нужен, окна под ним не двигаются
@MainActor final class PointerHider {
    private let backgroundControl = BackgroundCursorControl()
    private var coveredArea: NSRect?
    private var monitors: [Any] = []
    private var appSwitchObserver: (any NSObjectProtocol)?
    private(set) var hiddenByUs = false

    func engage(over frame: NSRect) {
        coveredArea = frame
        sync()
        guard monitors.isEmpty else { return }
        let moves: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        if let local = NSEvent.addLocalMonitorForEvents(matching: moves, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.sync() }
            return event
        }) { monitors.append(local) }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: moves, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.sync() }
        }) { monitors.append(global) }
        appSwitchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.showIfHidden()
                self?.sync()
            }
        }
    }

    func release() {
        coveredArea = nil
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        if let appSwitchObserver { NSWorkspace.shared.notificationCenter.removeObserver(appSwitchObserver) }
        appSwitchObserver = nil
        showIfHidden()
    }

    private func sync() {
        let overEffect = coveredArea?.contains(NSEvent.mouseLocation) ?? false
        switch pointerAction(hiddenByUs: hiddenByUs, overEffect: overEffect) {
        case .hide: hide()
        case .show: showIfHidden()
        case nil: break
        }
    }

    private func hide() {
        backgroundControl.allowBackgroundChanges(true)
        guard CGDisplayHideCursor(CGMainDisplayID()) == .success else {
            backgroundControl.allowBackgroundChanges(false)
            return
        }
        hiddenByUs = true
    }

    /// при неудаче курсор остаётся «нашим», следующая попытка повторит показ
    private func showIfHidden() {
        guard hiddenByUs, CGDisplayShowCursor(CGMainDisplayID()) == .success else { return }
        backgroundControl.allowBackgroundChanges(false)
        hiddenByUs = false
    }
}

/// публичный API прячет курсор только у активного приложения; фоновому нужно свойство соединения WindowServer
///
/// функции не документированы, поэтому ищутся во время работы; если их нет, курсор над чужими окнами останется видимым
@MainActor private final class BackgroundCursorControl {
    private typealias MainConnection = @convention(c) () -> UInt32
    private typealias SetProperty = @convention(c) (UInt32, UInt32, CFString, CFTypeRef) -> Int32

    private let mainConnection: MainConnection?
    private let setProperty: SetProperty?
    private var allowed = false

    init() {
        let process = dlopen(nil, RTLD_LAZY)
        mainConnection = dlsym(process, "CGSMainConnectionID").map { unsafeBitCast($0, to: MainConnection.self) }
        setProperty = dlsym(process, "CGSSetConnectionProperty").map { unsafeBitCast($0, to: SetProperty.self) }
        if let process { dlclose(process) }
    }

    func allowBackgroundChanges(_ allow: Bool) {
        guard allow != allowed, let mainConnection, let setProperty else { return }
        let connection = mainConnection()
        let value: CFBoolean = allow ? kCFBooleanTrue : kCFBooleanFalse
        if setProperty(connection, connection, "SetsCursorInBackground" as CFString, value) == 0 {
            allowed = allow
        }
    }
}
