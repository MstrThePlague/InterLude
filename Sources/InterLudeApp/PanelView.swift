import SwiftUI
import InterLudeCore

struct PanelView: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker("Station", selection: Binding(get: { model.selectedStationID }, set: { model.switchStation(to: $0) })) {
                    ForEach(model.orderedStations) { s in
                        Text((model.profile(s.serviceId).favourite ? "★ " : "") + s.name).tag(s.serviceId)
                    }
                }
                Button {
                    let id = model.selectedStationID
                    model.updateProfile(id) { $0.favourite.toggle() }
                } label: { Image(systemName: model.profile(model.selectedStationID).favourite ? "star.fill" : "star") }
                .buttonStyle(.borderless).help("Favourite")
            }

            Picker("Output", selection: $model.selectedOutputID) {
                ForEach(model.outputs) { Text($0.label).tag($0.id) }
            }
            .disabled(model.isPlaying || model.isStarting)

            HStack(spacing: 12) {
                Button(model.isPlaying || model.isStarting ? "Stop" : "Play") { model.togglePlay() }
                    .keyboardShortcut(.defaultAction)
                Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                Slider(value: $model.volume, in: 0...1)
                Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
            }

            Toggle("Mute news", isOn: Binding(
                get: { model.profile(model.selectedStationID).muteNews },
                set: { v in model.updateProfile(model.selectedStationID) { $0.muteNews = v } }))
                .disabled(model.selectedStation?.kind == .speech)
                .help(model.selectedStation?.kind == .speech ? "Speech is this station's programme." : "")

            VStack(alignment: .leading, spacing: 2) {
                Text(model.statusLine).font(.callout)
                if model.isPlaying, let np = model.status.nowPlaying { Text(np).font(.caption).foregroundStyle(.secondary) }
            }

            if model.isPlaying {
                HStack {
                    Button("That was news") { model.thatWasNews() }
                    if model.status.muted { Button("Not news") { model.notNews() } }
                }
                if !model.status.recentBlocks.isEmpty {
                    Divider()
                    Text("Recent muted blocks").font(.caption).foregroundStyle(.secondary)
                    ForEach(model.status.recentBlocks.prefix(5)) { b in
                        HStack {
                            Text(label(b)).font(.caption.monospacedDigit())
                            if b.falseStart { Text("wrong").font(.caption).foregroundStyle(.secondary) }
                            Spacer()
                            if !b.falseStart && !b.isOpen { Button("Wrong") { model.markWrong(b.id) }.buttonStyle(.borderless).font(.caption) }
                        }
                    }
                }
            }

            Divider()
            HStack {
                Button("Settings…") { openWindow(id: "settings"); NSApp.activate(ignoringOtherApps: true) }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 320)
    }

    private func label(_ b: NewsBlock) -> String {
        let f = DateFormatter(); f.timeStyle = .short
        let t = f.string(from: Date(timeIntervalSince1970: b.start))
        guard let e = b.end else { return "\(t), muted now" }
        let s = Int(e - b.start)
        return "\(t), \(s / 60) min \(s % 60) s"
    }
}
