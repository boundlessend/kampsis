import SwiftUI

/// поведение, доступ к экрану, состояние датчика и обновления
struct GeneralWindow: View {
    @Bindable var state: AppState
    let controller: EffectController
    let updates: UpdateChecker
    @State private var privacyShown = false

    private var sensorLine: String {
        if !state.settings.isOn || state.suspended { return "Не используется" }
        return state.sensorReady ? "Подключён" : "Недоступен"
    }

    var body: some View {
        Form {
            Section {
                Toggle("Щелчок, когда крышка открыта", isOn: $state.settings.chimeOnOpen)
                Toggle("Открывать при входе в систему", isOn: Binding(
                    get: { state.launchesAtLogin },
                    set: { controller.setOpensAtLogin($0) }
                ))
                LabeledContent("Включить или выключить эффект") {
                    Text("⌘⌥B").font(.body.monospaced())
                }
                if let shortcutProblem = state.shortcutProblem {
                    Text(shortcutProblem).foregroundStyle(.orange)
                }
            }

            Section("Доступ к экрану") {
                LabeledContent("Запись экрана") {
                    Label(state.screenAccess ? "Разрешена" : "Не разрешена",
                          systemImage: state.screenAccess ? "checkmark.circle" : "exclamationmark.circle")
                        .foregroundStyle(state.screenAccess ? Color.secondary : .orange)
                }
                if !state.screenAccess {
                    Text("Без доступа эффект не видит рабочий стол. Предпросмотр работает и так.")
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("Разрешить доступ…") { controller.requestScreenAccess() }
                            .buttonStyle(.glassProminent)
                        Button("Доступ включён, но не работает?") { controller.explainAccessRecovery() }
                            .buttonStyle(.link)
                    }
                }
                DisclosureGroup("Что происходит с изображением", isExpanded: $privacyShown) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Кадры живут только в памяти этого Mac и сразу заменяются следующими. \(AppIdentity.name) не сохраняет снимки, не записывает звук и ничего не отправляет в сеть.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Открыть настройки macOS") { controller.openScreenCaptureSettings() }
                            .buttonStyle(.link)
                    }
                    .padding(.top, 6)
                }
            }

            Section {
                LabeledContent("Модель Mac", value: controller.sensor.modelIdentifier)
                LabeledContent("Угол крышки", value: state.measuredAngle.map { "\(Int($0))°" } ?? "нет данных")
                LabeledContent("Датчик", value: sensorLine)
                LabeledContent("Эффект", value: state.statusLine)
                if let problem = state.problem {
                    Text(problem).foregroundStyle(.orange)
                }
                if state.settings.isOn, !state.suspended, !state.sensorReady {
                    Text(state.sensorNote).foregroundStyle(.secondary)
                }
                Button("Проверить ещё раз") { controller.retry() }
                    .buttonStyle(.link)
            } header: {
                Text("Состояние")
            } footer: {
                Text("Эффект показывается только на встроенном экране. Закрытый MacBook засыпает как обычно.")
            }

            Section("Обновления") {
                LabeledContent("Версия", value: AppIdentity.version)
                Toggle("Проверять раз в день", isOn: Binding(
                    get: { updates.checksAutomatically },
                    set: { updates.setChecksAutomatically($0) }
                ))
                Text("Сведения о новых выпусках берутся с GitHub. Скачать версию или нет, решаете вы.")
                    .foregroundStyle(.secondary)
                Button("Проверить обновления…") { updates.checkFromMenu() }
                    .disabled(updates.checking)
            }
        }
        .formStyle(.grouped)
    }
}
