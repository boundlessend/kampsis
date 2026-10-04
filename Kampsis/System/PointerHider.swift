import AppKit
import CoreGraphics
import Darwin
import os

private let pointerLog = Logger(subsystem: "io.github.boundlessend.kampsis", category: "pointer")

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
    private var restoreJob: Task<Void, Never>?
    private var restoreSession = 0
    var onProblem: ((String?) -> Void)?
    private(set) var hiddenByUs = false

    var backgroundProblem: String? { backgroundControl.problem }

    func engage(over frame: NSRect) {
        restoreSession += 1
        restoreJob?.cancel()
        restoreJob = nil
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
        guard hiddenByUs, restoreJob == nil else { return }
        restoreSession += 1
        let session = restoreSession
        restoreJob = Task { [weak self] in
            guard let self else { return }
            defer { if self.restoreSession == session { self.restoreJob = nil } }
            for _ in 0..<3 {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                self.showIfHidden()
                if !self.hiddenByUs { return }
            }
            let problem = String(localized: "The cursor couldn’t be restored. Move the pointer or switch to another app, then click “Check Again”.")
            pointerLog.error("cursor restore failed after retries")
            self.onProblem?(problem)
        }
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
        onProblem?(backgroundControl.problem)
        let status = CGDisplayHideCursor(CGMainDisplayID())
        guard status == .success else {
            pointerLog.warning("cursor hide failed: code=\(status.rawValue, privacy: .public)")
            backgroundControl.allowBackgroundChanges(false)
            return
        }
        hiddenByUs = true
    }

    /// при неудаче курсор остаётся «нашим», следующая попытка повторит показ
    private func showIfHidden() {
        guard hiddenByUs else { return }
        let status = CGDisplayShowCursor(CGMainDisplayID())
        guard status == .success else {
            pointerLog.warning("cursor restore failed: code=\(status.rawValue, privacy: .public)")
            return
        }
        backgroundControl.allowBackgroundChanges(false)
        hiddenByUs = false
        onProblem?(backgroundControl.problem)
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
    private(set) var problem: String?

    init() {
        let process = dlopen(nil, RTLD_LAZY)
        mainConnection = dlsym(process, "CGSMainConnectionID").map { unsafeBitCast($0, to: MainConnection.self) }
        setProperty = dlsym(process, "CGSSetConnectionProperty").map { unsafeBitCast($0, to: SetProperty.self) }
        if let process { dlclose(process) }
        if mainConnection == nil || setProperty == nil {
            problem = String(localized: "This macOS version doesn’t provide background cursor control. The pointer may stay visible over the effect.")
            pointerLog.warning("background cursor API unavailable")
        }
    }

    func allowBackgroundChanges(_ allow: Bool) {
        guard allow != allowed, let mainConnection, let setProperty else { return }
        let connection = mainConnection()
        let value: CFBoolean = allow ? kCFBooleanTrue : kCFBooleanFalse
        let status = setProperty(connection, connection, "SetsCursorInBackground" as CFString, value)
        if status == 0 {
            allowed = allow
            problem = nil
        } else {
            problem = String(localized: "macOS couldn’t change background cursor visibility (code \(status)).")
            pointerLog.warning("background cursor property rejected: code=\(status, privacy: .public) enabled=\(allow, privacy: .public)")
        }
    }
}
