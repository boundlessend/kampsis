import AppKit
import SwiftUI

/// главное окно: предпросмотр слева, стиль и параметры справа
struct EffectWindow: View {
    @Bindable var state: AppState
    let controller: EffectController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                HStack(alignment: .top, spacing: 32) {
                    PreviewColumn(state: state, controller: controller)
                    EffectInspector(state: state)
                        .frame(width: 270)
                }
                .padding(24)
            }
        }
        .background(.background)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 30, height: 30)
                .accessibilityHidden(true)
            Text(AppIdentity.name)
                .font(.system(size: 20, weight: .semibold, design: .rounded))
            Spacer()
            Toggle("Эффект", isOn: $state.settings.isOn)
                .toggleStyle(.switch)
                .controlSize(.small)
            Divider()
                .frame(height: 18)
                .padding(.horizontal, 6)
            Button {
                openWindow(id: SceneID.general)
            } label: {
                Label("Общие настройки", systemImage: "slider.horizontal.3")
            }
            .buttonStyle(.borderless)
            .help("Общие настройки, ⌘,")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }
}

private struct PreviewColumn: View {
    @Bindable var state: AppState
    let controller: EffectController

    private var shownAngle: Int {
        Int(state.previewUsesLid ? (state.measuredAngle ?? 0) : state.previewAngle)
    }

    private var hint: String {
        if state.previewUsesLid { return "Прикройте крышку, и пример сложится вместе с ней." }
        if state.previewAngle >= state.settings.fadeOutAngle {
            return "При \(Int(state.settings.fadeOutAngle))° и шире эффекта не видно, сдвиньте ползунок левее."
        }
        return "Ведите ползунок, чтобы пройти весь путь от открытой крышки до закрытой."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Предпросмотр").font(.headline)
                Spacer()
                Text("пример рабочего стола").font(.callout).foregroundStyle(.secondary)
            }
            PreviewPane(state: state)
                .aspectRatio(1.6, contentMode: .fit)
                .clipShape(.rect(cornerRadius: 11))
                .padding(6)
                .background(.black, in: .rect(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.primary.opacity(0.1)))
                .accessibilityLabel("Пример рабочего стола под эффектом")

            HStack(spacing: 12) {
                Picker("Источник угла", selection: $state.previewUsesLid) {
                    Text("Ползунок").tag(false)
                    Text("Крышка").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 190)
                .disabled(!state.sensorReady)
                .onChange(of: state.sensorReady) { _, ready in
                    if !ready { state.previewUsesLid = false }
                }
                Spacer(minLength: 0)
                Text("\(state.previewUsesLid ? "Крышка" : "Пример"): \(shownAngle)°")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: $state.previewAngle, in: fullyFoldedAngle...EffectSettings.fadeOutRange.upperBound, step: 1)
                .disabled(state.previewUsesLid)
                .accessibilityLabel("Угол крышки в примере")
                .accessibilityValue("\(shownAngle) градусов")
            Text(hint).font(.callout).foregroundStyle(.secondary)

            Divider().padding(.vertical, 4)
            demoRow
            problemRow
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var demoRow: some View {
        HStack(spacing: 12) {
            if state.screenAccess {
                Button {
                    if state.demoRunning { controller.endDemo() } else { controller.beginDemo() }
                } label: {
                    Label(state.demoRunning ? "Остановить" : "Показать на экране",
                          systemImage: state.demoRunning ? "stop.fill" : "play.fill")
                        .padding(.horizontal, 4)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                Text(state.demoRunning ? "⌘⌥B остановит" : "Пять секунд\nна вашем рабочем столе")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Button("Разрешить доступ к экрану…") { controller.requestScreenAccess() }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                Text("Нужен, чтобы эффект\nработал на вашем экране")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private var problemRow: some View {
        if let problem = state.problem {
            VStack(alignment: .leading, spacing: 4) {
                Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                Button("Проверить ещё раз") { controller.retry() }.buttonStyle(.link)
            }
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
        } else if state.settings.isOn, !state.sensorReady {
            Label("Датчик крышки недоступен, но демонстрация работает.", systemImage: "info.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

private struct EffectInspector: View {
    @Bindable var state: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Стиль").font(.headline)
            HStack(spacing: 8) {
                ForEach(Look.allCases) { look in
                    LookTile(look: look, selected: state.settings.look == look) {
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                            state.settings = state.settings.applying(look)
                        }
                    }
                }
            }
            Text(state.settings.isCustomized ? "\(state.settings.look.summary), изменён" : state.settings.look.summary)
                .font(.callout)
                .foregroundStyle(.secondary)

            Divider()
            VStack(spacing: 16) {
                percentSlider("Изгиб", value: $state.settings.bend)
                percentSlider("Размытие", value: $state.settings.blur)
                percentSlider("Затемнение", value: $state.settings.dimming)
            }

            Divider()
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Исчезает при")
                    Spacer()
                    Text("\(Int(state.settings.fadeOutAngle))°").monospacedDigit().foregroundStyle(.secondary)
                }
                Slider(value: $state.settings.fadeOutAngle, in: EffectSettings.fadeOutRange, step: 1)
                    .accessibilityLabel("Угол, при котором эффект исчезает")
                    .accessibilityValue("\(Int(state.settings.fadeOutAngle)) градусов")
                Text("Когда крышка открыта на \(Int(state.settings.fadeOutAngle))° и шире, экран остаётся обычным.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("Вернуть стандартный вид") { state.settings = state.settings.resettingAppearance() }
                .buttonStyle(.link)
                .font(.callout)
                .help("Стиль, ползунки и угол исчезновения вернутся к исходным. Звук и автозапуск не изменятся.")
        }
    }

    private func percentSlider(_ title: String, value: Binding<Double>) -> some View {
        VStack(spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int((value.wrappedValue * 100).rounded()))%").monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: value, in: 0...1)
                .accessibilityLabel(title)
                .accessibilityValue("\(Int((value.wrappedValue * 100).rounded())) процентов")
        }
    }
}

private struct LookTile: View {
    let look: Look
    let selected: Bool
    let choose: () -> Void

    var body: some View {
        Button(action: choose) {
            VStack(spacing: 7) {
                ZStack(alignment: .topTrailing) {
                    if let thumbnail = StyleThumbnails.imageOrNil(for: look) {
                        Image(nsImage: thumbnail).resizable().aspectRatio(1.6, contentMode: .fit)
                    } else {
                        Rectangle().fill(.quaternary).aspectRatio(1.6, contentMode: .fit)
                    }
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, Color.accentColor)
                            .padding(4)
                    }
                }
                .clipShape(.rect(cornerRadius: 7))
                .padding(3)
                .overlay(RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(selected ? Color.accentColor : .primary.opacity(0.12), lineWidth: selected ? 2 : 1))
                Text(look.title).font(.callout.weight(selected ? .semibold : .regular))
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(look.title): \(look.summary.lowercased())")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
