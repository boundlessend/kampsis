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
            Toggle("Effect", isOn: $state.settings.isOn)
                .toggleStyle(.switch)
                .controlSize(.small)
            Divider()
                .frame(height: 18)
                .padding(.horizontal, 6)
            Button {
                openWindow(id: SceneID.general)
            } label: {
                Label("General Settings", systemImage: "slider.horizontal.3")
            }
            .buttonStyle(.borderless)
            .help("General Settings, ⌘,")
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
        if state.previewUsesLid { return String(localized: "Lower the lid and the sample folds along with it.") }
        if state.previewAngle >= state.settings.fadeOutAngle {
            return String(localized: "At \(Int(state.settings.fadeOutAngle))° and wider the effect isn’t visible. Move the slider to the left.")
        }
        return String(localized: "Drag the slider to go all the way from an open lid to a closed one.")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Preview").font(.headline)
                Spacer()
                Text("sample desktop").font(.callout).foregroundStyle(.secondary)
            }
            PreviewPane(state: state)
                .aspectRatio(1.6, contentMode: .fit)
                .clipShape(.rect(cornerRadius: 11))
                .padding(6)
                .background(.black, in: .rect(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.primary.opacity(0.1)))
                .accessibilityLabel("Sample desktop under the effect")

            HStack(spacing: 12) {
                Picker("Angle Source", selection: $state.previewUsesLid) {
                    Text("Slider").tag(false)
                    Text("Lid").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 190)
                .disabled(!state.sensorReady)
                .onChange(of: state.sensorReady) { _, ready in
                    if !ready { state.previewUsesLid = false }
                }
                Spacer(minLength: 0)
                Group {
                    if state.previewUsesLid { Text("Lid: \(shownAngle)°") } else { Text("Sample: \(shownAngle)°") }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
            Slider(value: $state.previewAngle, in: fullyFoldedAngle...EffectSettings.fadeOutRange.upperBound, step: 1)
                .disabled(state.previewUsesLid)
                .accessibilityLabel("Lid angle in the sample")
                .accessibilityValue("\(shownAngle) degrees")
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
                    Group {
                        if state.demoRunning {
                            Label("Stop", systemImage: "stop.fill")
                        } else {
                            Label("Show on Screen", systemImage: "play.fill")
                        }
                    }
                    .padding(.horizontal, 4)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                Group {
                    if state.demoRunning { Text("\(shortcutLabel(state.settings.toggleShortcut)) stops it") } else { Text("Five seconds\non your desktop") }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            } else {
                Button("Allow Screen Access…") { controller.requestScreenAccess() }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                Text("Needed for the effect\nto work on your screen")
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
                Button("Check Again") { controller.retry() }.buttonStyle(.link)
            }
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
        } else if state.settings.isOn, !state.sensorReady {
            Label("The lid sensor is unavailable, but the demo still works.", systemImage: "info.circle")
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
            Text("Style").font(.headline)
            HStack(spacing: 8) {
                ForEach(Look.allCases) { look in
                    LookTile(look: look, selected: state.settings.look == look) {
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                            state.settings = state.settings.applying(look)
                        }
                    }
                }
            }
            Text(state.settings.isCustomized ? String(localized: "\(state.settings.look.summary), modified") : state.settings.look.summary)
                .font(.callout)
                .foregroundStyle(.secondary)

            Divider()
            VStack(spacing: 16) {
                percentSlider("Bend", value: $state.settings.bend)
                percentSlider("Blur", value: $state.settings.blur)
                percentSlider("Dimming", value: $state.settings.dimming)
            }

            Divider()
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Fades out at")
                    Spacer()
                    Text("\(Int(state.settings.fadeOutAngle))°").monospacedDigit().foregroundStyle(.secondary)
                }
                Slider(value: $state.settings.fadeOutAngle, in: EffectSettings.fadeOutRange, step: 1)
                    .accessibilityLabel("Angle at which the effect fades out")
                    .accessibilityValue("\(Int(state.settings.fadeOutAngle)) degrees")
                Text("When the lid is open \(Int(state.settings.fadeOutAngle))° or wider, the screen stays as it is.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("Animation pace")
                HStack(spacing: 8) {
                    Text("Faster").font(.callout).foregroundStyle(.secondary)
                    Slider(value: $state.settings.pace, in: EffectSettings.paceRange)
                        .accessibilityLabel("Animation pace")
                    Text("Slower").font(.callout).foregroundStyle(.secondary)
                }
                Text("Anticipation").padding(.top, 8)
                HStack(spacing: 8) {
                    Text("Exact").font(.callout).foregroundStyle(.secondary)
                    Slider(value: $state.settings.prediction, in: EffectSettings.predictionRange)
                        .accessibilityLabel("Anticipation")
                    Text("Earlier").font(.callout).foregroundStyle(.secondary)
                }
            }
            Button("Restore Default Look") { state.settings = state.settings.resettingAppearance() }
                .buttonStyle(.link)
                .font(.callout)
                .help("Style, sliders, and fade-out angle return to their defaults. Sound and launch at login stay as they are.")
        }
    }

    private func percentSlider(_ title: LocalizedStringKey, value: Binding<Double>) -> some View {
        VStack(spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int((value.wrappedValue * 100).rounded()))%").monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: value, in: 0...1)
                .accessibilityLabel(title)
                .accessibilityValue("\(Int((value.wrappedValue * 100).rounded())) percent")
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
        .accessibilityLabel(Text(verbatim: "\(look.title): \(look.summary.lowercased())"))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
