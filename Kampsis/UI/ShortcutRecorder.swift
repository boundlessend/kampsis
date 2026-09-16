import AppKit
import Carbon.HIToolbox
import SwiftUI

/// кнопка записи сочетания: после щелчка ждёт нажатия, Esc без модификаторов отменяет запись
struct ShortcutRecorder: View {
    @Binding var shortcut: ToggleShortcut
    @State private var monitor: Any?

    var body: some View {
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
        .onDisappear { stopRecording() }
    }

    private func startRecording() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let modifiers = shortcutModifiers(event.modifierFlags)
            if event.keyCode == UInt16(kVK_Escape), modifiers.isEmpty {
                stopRecording()
                return nil
            }
            let candidate = ToggleShortcut(keyCode: event.keyCode, modifiers: modifiers)
            guard candidate.isAcceptable else {
                NSSound.beep()
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
    }
}
