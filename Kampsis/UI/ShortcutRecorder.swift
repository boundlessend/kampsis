import AppKit
import Carbon.HIToolbox
import SwiftUI

/// кнопка записи сочетания: после щелчка ждёт нажатия, Esc без модификаторов отменяет запись
struct ShortcutRecorder: View {
    @Binding var shortcut: ToggleShortcut
    @State private var monitor: Any?
    @State private var recordingWindow: NSWindow?
    @State private var inputProblem: String?

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            HStack(spacing: 8) {
                Button {
                    if monitor == nil { startRecording() } else { stopRecording() }
                } label: {
                    Group {
                        if monitor == nil {
                            Text(verbatim: shortcutLabel(shortcut))
                        } else {
                            Text("Press keys…")
                        }
                    }
                    .font(.body.monospaced())
                    .frame(minWidth: 96)
                }
                if monitor == nil, shortcut != .standard {
                    Button("Reset") { shortcut = .standard }
                        .buttonStyle(.link)
                }
            }
            if let inputProblem {
                Text(inputProblem).font(.callout).foregroundStyle(.orange)
            }
        }
        .onDisappear { stopRecording() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in stopRecording() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { notification in
            if notification.object as? NSWindow === recordingWindow { stopRecording() }
        }
    }

    private func startRecording() {
        inputProblem = nil
        recordingWindow = NSApp.keyWindow
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.window === recordingWindow else {
                stopRecording()
                return event
            }
            let modifiers = shortcutModifiers(event.modifierFlags)
            if event.keyCode == UInt16(kVK_Escape), modifiers.isEmpty {
                stopRecording()
                return nil
            }
            let candidate = ToggleShortcut(keyCode: event.keyCode, modifiers: modifiers)
            guard candidate.isAcceptable else {
                inputProblem = String(localized: "Include Command, Option, or Control in the shortcut.")
                return nil
            }
            shortcut = candidate
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recordingWindow = nil
        inputProblem = nil
    }
}
