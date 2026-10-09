import AppKit
import Carbon
import Darwin
import Foundation
import os
import Synchronization

enum CaptureLaunchRoute {
    case application
    case terminal
}

enum CaptureLaunchFailure: LocalizedError, Sendable {
    case invalidHandoff
    case parentStillRunning
    case automationDenied
    case terminalNotClosed
    case helperTimedOut
    case helperFailed(Int32)
    case applicationNotStarted
    case openTimedOut
    case cleanupFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidHandoff, .applicationNotStarted:
            String(localized: "Kampsis didn’t restart. Open the installed app and try again.")
        case .parentStillRunning:
            String(localized: "The previous Kampsis process didn’t quit. Close it before trying again.")
        case .automationDenied:
            String(localized: "Allow Kampsis to control Terminal in macOS Settings > Privacy & Security > Automation, then try again.")
        case .terminalNotClosed:
            String(localized: "Kampsis couldn’t close its Terminal window safely. Close that window and try again. Other Terminal windows were left open.")
        case .helperTimedOut:
            String(localized: "Terminal didn’t finish the launch in time. Check the permission dialog and try again.")
        case .openTimedOut:
            String(localized: "macOS didn’t confirm the app launch in time. Check whether it opened before trying again.")
        case let .helperFailed(status):
            String(localized: "Terminal launch failed (status \(status)). Open the installed app and try again.")
        case let .cleanupFailed(reason):
            String(localized: "Terminal remained open after launch failed: \(reason) Close the launch window and try again.")
        }
    }
}

/// перезапускает тот же bundle; Terminal получает только команду запуска в отдельном окне
@MainActor enum CaptureLaunch {
    private static let log = Logger(subsystem: "io.github.boundlessend.kampsis", category: "launch")
    static let preferenceKey = "shows-capture-indicator"
    static var isTerminalSession: Bool { ProcessInfo.processInfo.arguments.contains("--terminal-launch") }

    /// проверяет разрешение для уже запущенного Terminal; запрос выполняется в процессе без окон
    static func terminalAuthorization(request: Bool) -> OSStatus {
        let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.Terminal")
        return AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, request)
    }

    /// новый экземпляр подтверждает подготовку и ждёт явного освобождения ресурсов родителем
    static func completeHandoff() async throws {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--launch-parent") || arguments.contains("--launch-token") else { return }
        guard let parentText = value(after: "--launch-parent", in: arguments),
              let parentID = Int32(parentText), parentID > 0, parentID != ProcessInfo.processInfo.processIdentifier,
              let tokenText = value(after: "--launch-token", in: arguments), let token = UUID(uuidString: tokenText),
              let parent = NSRunningApplication(processIdentifier: parentID),
              parent.bundleURL == Bundle.main.bundleURL else { throw CaptureLaunchFailure.invalidHandoff }
        let marker = launchDirectory(token).appendingPathComponent("ready")
        do { try String(ProcessInfo.processInfo.processIdentifier).write(to: marker, atomically: true, encoding: .utf8) }
        catch { throw CaptureLaunchFailure.invalidHandoff }
        let released = launchDirectory(token).appendingPathComponent("released")
        let deadline = ContinuousClock.now + .seconds(110)
        while !FileManager.default.fileExists(atPath: released.path) {
            guard FileManager.default.fileExists(atPath: launchDirectory(token).path) else { throw CaptureLaunchFailure.invalidHandoff }
            guard !parent.isTerminated else { throw CaptureLaunchFailure.invalidHandoff }
            guard ContinuousClock.now < deadline else { throw CaptureLaunchFailure.parentStillRunning }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    /// подтверждение записывается только после запуска контроллера и интерфейса
    static func confirmStarted() throws {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--launch-parent") else { return }
        guard let tokenText = value(after: "--launch-token", in: arguments), let token = UUID(uuidString: tokenText) else {
            throw CaptureLaunchFailure.invalidHandoff
        }
        do {
            try String(ProcessInfo.processInfo.processIdentifier).write(
                to: launchDirectory(token).appendingPathComponent("active"), atomically: true, encoding: .utf8)
        } catch { throw CaptureLaunchFailure.invalidHandoff }
    }

    /// успех означает, что новый экземпляр уже отвечает, а служебное окно Terminal закрыто
    static func restart(via route: CaptureLaunchRoute, background: Bool,
                        releaseResources: @MainActor () async throws -> Void) async throws {
        guard let executable = Bundle.main.executableURL else { throw CaptureLaunchFailure.applicationNotStarted }
        let token = UUID()
        let directory = launchDirectory(token)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        defer {
            do { try FileManager.default.removeItem(at: directory) }
            catch {
                log.error("launch temporary directory cleanup failed: code=\((error as NSError).code, privacy: .public)")
            }
        }
        var arguments = ["--launch-parent", String(ProcessInfo.processInfo.processIdentifier),
                         "--launch-token", token.uuidString]
        if background { arguments.append("--background-launch") }
        if let diagnostics = value(after: "--diagnostics", in: ProcessInfo.processInfo.arguments) {
            arguments += ["--diagnostics", diagnostics]
        }
        switch route {
        case .application:
            arguments.append("--standard-launch")
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.createsNewApplicationInstance = true
            configuration.activates = !background
            configuration.arguments = arguments
            _ = try await openApplication(at: Bundle.main.bundleURL, configuration: configuration)
        case .terminal:
            arguments.append("--terminal-launch")
            try await runTerminal(executable: executable, arguments: arguments, directory: directory, token: token)
        }
        let marker = directory.appendingPathComponent("ready")
        let deadline = ContinuousClock.now + .seconds(5)
        while !FileManager.default.fileExists(atPath: marker.path) {
            guard ContinuousClock.now < deadline else { throw CaptureLaunchFailure.applicationNotStarted }
            try await Task.sleep(for: .milliseconds(50))
        }
        let childText = try String(contentsOf: marker, encoding: .utf8)
        guard let childID = Int32(childText), childID != ProcessInfo.processInfo.processIdentifier,
              let child = NSRunningApplication(processIdentifier: childID),
              !child.isTerminated, child.bundleURL == Bundle.main.bundleURL else {
            throw CaptureLaunchFailure.applicationNotStarted
        }
        try await releaseResources()
        try "released".write(to: directory.appendingPathComponent("released"), atomically: true, encoding: .utf8)
        let activeMarker = directory.appendingPathComponent("active")
        // первый запрос разрешения Terminal может ждать решения человека
        let activeDeadline = ContinuousClock.now + .seconds(90)
        while !FileManager.default.fileExists(atPath: activeMarker.path) {
            guard !child.isTerminated, ContinuousClock.now < activeDeadline else {
                throw CaptureLaunchFailure.applicationNotStarted
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        let activePID = try String(contentsOf: activeMarker, encoding: .utf8)
        guard Int32(activePID) == childID, !child.isTerminated else { throw CaptureLaunchFailure.applicationNotStarted }
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    private static func launchDirectory(_ token: UUID) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("KampsisLaunch-\(token.uuidString)", isDirectory: true)
    }

    /// отдельный osascript позволяет ограничить ожидание разрешения, не блокируя интерфейс
    private static func runTerminal(executable: URL, arguments: [String], directory: URL, token: UUID) async throws {
        let wasRunning = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Terminal")
            .contains { !$0.isTerminated }
        let terminalUsed = Mutex(false)
        let notifications = NSWorkspace.shared.notificationCenter
        let observer = notifications.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                 object: nil, queue: .main) { notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == "com.apple.Terminal" else { return }
            terminalUsed.withLock { $0 = true }
        }
        defer { notifications.removeObserver(observer) }
        var ownedTerminal: NSRunningApplication?
        if !wasRunning {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            configuration.hides = true
            configuration.arguments = ["-ApplePersistenceIgnoreState", "YES"]
            ownedTerminal = try await openApplication(
                at: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"), configuration: configuration)
        }
        do {
            let permission = try await runProcess(executable: executable, arguments: ["--terminal-automation-check"])
            guard permission.status == 0 else { throw CaptureLaunchFailure.helperFailed(permission.status) }
            guard let permissionCode = Int32(permission.output) else { throw CaptureLaunchFailure.applicationNotStarted }
            if permissionCode == errAEEventNotPermitted || permissionCode == errAEEventWouldRequireUserConsent {
                throw CaptureLaunchFailure.automationDenied
            }
            guard permissionCode == noErr else { throw CaptureLaunchFailure.helperFailed(permissionCode) }
            let ownership = wasRunning || terminalUsed.withLock({ $0 }) ? "existing" : "owned"
            let result = try await runProcess(executable: URL(fileURLWithPath: "/usr/bin/osascript"),
                                             arguments: ["-e", terminalScript, executable.path, "Kampsis-\(token.uuidString)",
                                                         directory.appendingPathComponent("status").path, ownership] + arguments)
            guard result.status == 0, result.output == "ok" else {
                if result.error.contains("(-1743)") { throw CaptureLaunchFailure.automationDenied }
                if result.error.contains("(9002)") { throw CaptureLaunchFailure.terminalNotClosed }
                if let range = result.error.range(of: #"\(-?\d+\)"#, options: .regularExpression),
                   let code = Int32(result.error[range].dropFirst().dropLast()) {
                    throw CaptureLaunchFailure.helperFailed(code)
                }
                throw CaptureLaunchFailure.helperFailed(result.status)
            }
            let statusURL = directory.appendingPathComponent("status")
            let deadline = ContinuousClock.now + .seconds(5)
            while !FileManager.default.fileExists(atPath: statusURL.path) {
                guard ContinuousClock.now < deadline else { throw CaptureLaunchFailure.applicationNotStarted }
                try await Task.sleep(for: .milliseconds(50))
            }
            let status = try String(contentsOf: statusURL, encoding: .utf8)
            guard status == "0" else { throw CaptureLaunchFailure.helperFailed(Int32(status) ?? -1) }
        } catch {
            if let ownedTerminal, !terminalUsed.withLock({ $0 }), !ownedTerminal.isTerminated {
                guard ownedTerminal.terminate() else { throw CaptureLaunchFailure.cleanupFailed(error.localizedDescription) }
                let deadline = ContinuousClock.now + .seconds(5)
                while !ownedTerminal.isTerminated, ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(50))
                }
                guard ownedTerminal.isTerminated else { throw CaptureLaunchFailure.cleanupFailed(error.localizedDescription) }
            }
            throw error
        }
    }

    private struct ProcessResult {
        let status: Int32
        let output: String
        let error: String
    }

    /// ссылка на объект SDK передаётся из callback только для последующего использования главным актором
    private struct OpenedApplication: @unchecked Sendable {
        let app: NSRunningApplication
    }

    private static func openApplication(at url: URL, configuration: NSWorkspace.OpenConfiguration) async throws -> NSRunningApplication {
        let reply = SystemReply<OpenedApplication, CaptureLaunchFailure>()
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { app, error in
            if let error { reply.finish(.failure(.helperFailed(Int32(clamping: (error as NSError).code)))) }
            else if let app { reply.finish(.success(OpenedApplication(app: app))) }
            else { reply.finish(.failure(.applicationNotStarted)) }
        }
        return try await reply.wait(until: ContinuousClock.now + .seconds(10), timeout: .openTimedOut).app
    }

    /// запускает один служебный процесс с ограниченным ожиданием; вывод не попадает в пользовательские логи
    private static func runProcess(executable: URL, arguments: [String]) async throws -> ProcessResult {
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        defer { if process.isRunning { process.terminate() } }
        let deadline = ContinuousClock.now + .seconds(90)
        while process.isRunning {
            if ContinuousClock.now >= deadline || Task.isCancelled {
                process.terminate()
                let stopDeadline = ContinuousClock.now + .seconds(2)
                while process.isRunning, ContinuousClock.now < stopDeadline {
                    try await Task.sleep(for: .milliseconds(50))
                }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                throw CaptureLaunchFailure.helperTimedOut
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        let result = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let error = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return ProcessResult(status: process.terminationStatus,
                             output: result.trimmingCharacters(in: .whitespacesAndNewlines), error: error)
    }

    /// не завершает уже работавший Terminal и не закрывает окно, в которое человек добавил вкладку
    private static let terminalScript = #"""
    on closeLaunchWindow(windowID, launchTTY, wasRunning)
        if not (application "Terminal" is running) then return
        tell application "Terminal"
            if windowID is not 0 and (exists window id windowID) then
                set launchWindow to window id windowID
                if (count of tabs of launchWindow) is not 0 then
                    if (count of tabs of launchWindow) is not 1 then error number 9002
                    if tty of selected tab of launchWindow is not launchTTY then error number 9002
                    if busy of selected tab of launchWindow then error number 9002
                    close launchWindow saving no
                    repeat 50 times
                        if not (exists window id windowID) then exit repeat
                        if (count of tabs of window id windowID) is 0 then exit repeat
                        delay 0.1
                    end repeat
                    if exists window id windowID then
                        if (count of tabs of window id windowID) is not 0 then error number 9002
                    end if
                end if
            end if
            if not wasRunning then
                set otherWindowExists to false
                set windowIDs to id of every window
                repeat with identifierRef in windowIDs
                    set remainingID to contents of identifierRef
                    if visible of window id remainingID or (count of tabs of window id remainingID) is not 0 then
                        set otherWindowExists to true
                    end if
                end repeat
                if not otherWindowExists then quit
            end if
        end tell
    end closeLaunchWindow

    on run argv
        set wasRunning to (item 4 of argv is "existing")
        set windowID to 0
        set launchTTY to ""
        set commandText to "/usr/bin/screen -c /dev/null -dmS " & quoted form of item 2 of argv & " " & quoted form of item 1 of argv
        repeat with argument in items 5 thru -1 of argv
            set commandText to commandText & " " & quoted form of (argument as text)
        end repeat
        set statusPath to item 3 of argv
        set commandText to commandText & "; kampsis_launch_status=$?; printf '%s' \"$kampsis_launch_status\" > " & quoted form of statusPath
        try
            with timeout of 30 seconds
                tell application "Terminal"
                    set startupWindows to {}
                    if not wasRunning then
                        set startupIDs to id of every window
                        repeat with identifierRef in startupIDs
                            set candidateID to contents of identifierRef
                            if (count of tabs of window id candidateID) is not 0 then
                                set end of startupWindows to candidateID
                            end if
                        end repeat
                    end if
                    if (count of startupWindows) is 1 then
                        set startupWindow to window id (item 1 of startupWindows)
                        if (count of tabs of startupWindow) is not 1 then error number 9002
                        repeat 50 times
                            if not (busy of selected tab of startupWindow) then exit repeat
                            delay 0.1
                        end repeat
                        if busy of selected tab of startupWindow then error number 9002
                        set launchTab to do script commandText in selected tab of startupWindow
                    else
                        set launchTab to do script commandText
                    end if
                    set launchTTY to tty of launchTab
                    set candidateIDs to id of every window
                    repeat with identifierRef in candidateIDs
                        set candidateID to contents of identifierRef
                        if (count of tabs of window id candidateID) is not 0 then
                            set candidateTabs to tabs of window id candidateID
                            repeat with tabRef in candidateTabs
                                set candidateTab to contents of tabRef
                                if tty of candidateTab is launchTTY then set windowID to candidateID
                            end repeat
                        end if
                    end repeat
                    if windowID is 0 then error number 9002
                end tell
                repeat 50 times
                    set commandFinished to do shell script "/usr/bin/test -f " & quoted form of statusPath & " && printf ready || printf waiting"
                    tell application "Terminal"
                        if commandFinished is "ready" and not (busy of launchTab) then exit repeat
                    end tell
                    delay 0.1
                end repeat
                my closeLaunchWindow(windowID, launchTTY, wasRunning)
            end timeout
        on error messageText number errorNumber
            try
                with timeout of 10 seconds
                    my closeLaunchWindow(windowID, launchTTY, wasRunning)
                end timeout
            on error
                error number 9002
            end try
            error number errorNumber
        end try
        return "ok"
    end run
    """#
}
