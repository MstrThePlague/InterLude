import SwiftUI
import AppKit
import InterLudeCore

struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var stationID: String = ""
    @State private var slots: String = ""

    private var station: Station? { model.stations.first { $0.serviceId == stationID } }

    var body: some View {
        Form {
            Section {
                Picker("Station", selection: $stationID) {
                    ForEach(model.orderedStations) { Text($0.name).tag($0.serviceId) }
                }
                if station != nil {
                    let p = model.profile(stationID)
                    SliderRow(title: "Delay behind live", value: p.delaySeconds, range: 30...600, step: 5, unit: "s") { v in
                        model.updateProfile(stationID) { $0.delaySeconds = v }
                    }
                    if station?.kind == .music {
                        SliderRow(title: "Longest mute", value: p.detector.maxMuteSeconds / 60, range: 5...20, step: 1, unit: "min") { v in
                            model.updateProfile(stationID) { $0.detector.maxMuteSeconds = v * 60 }
                        }
                    }
                    if model.isPlaying && stationID == model.selectedStationID {
                        LabeledContent("Changes apply when playback restarts") {
                            Button("Restart now") { model.restartToApply() }.controlSize(.small)
                        }
                        .foregroundStyle(.secondary)
                    }
                }
            } header: { Text("Playback") } footer: {
                FooterText("A longer delay gives InterLude more time to recognise a bulletin before you hear it.")
            }

            if let st = station, st.kind == .music {
                let p = model.profile(stationID)
                Section {
                    TextField("Bulletin minutes", text: $slots, prompt: Text("0, 30"))
                        .onSubmit { commitSlots() }
                    Toggle(isOn: Binding(get: { p.detector.identOnly }, set: { v in model.updateProfile(stationID) { $0.detector.identOnly = v } })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Mute only when the news jingle plays")
                            if p.idents.isEmpty {
                                Text(p.detector.identOnly ? "No jingle learned yet, so nothing is being muted." : "Available once a jingle is learned.")
                                    .font(.caption).foregroundStyle(p.detector.identOnly ? Color.orange : Color.secondary)
                            }
                        }
                    }
                    .disabled(p.idents.isEmpty && !p.detector.identOnly)
                    Toggle("Shadow mode: note bulletins, never mute", isOn: Binding(get: { p.shadowMode }, set: { v in model.updateProfile(stationID) { $0.shadowMode = v } }))
                    LabeledContent("News jingle") {
                        HStack {
                            Text(model.jingleStatus(stationID)).foregroundStyle(.secondary)
                            if !p.idents.isEmpty || !p.candidates.isEmpty {
                                Button("Forget") { model.updateProfile(stationID) { $0.idents = []; $0.candidates = [] } }.controlSize(.small)
                            }
                        }
                    }
                } header: { Text("News detection for \(st.name)") } footer: {
                    FooterText("Bulletin minutes are when bulletins usually start, in minutes past the hour. Speech from a minute before to three minutes after counts as news. InterLude listens for a jingle that recurs at the start of bulletins, learning from each one it mutes and each “News got through”. Once three agree, it mutes as soon as the jingle plays.")
                }
            }

            Section {
                Picker("Bitrate", selection: $model.bitrate) { Text("128 kbps").tag(128_000); Text("320 kbps").tag(320_000) }
                TextField("Server port", value: $model.port, format: .number.grouping(.never))
                Toggle("Keep this Mac awake while playing", isOn: $model.keepAwake)
                Toggle("Start at login", isOn: Binding(get: { model.startAtLogin }, set: { model.setStartAtLogin($0) }))
            } header: { Text("General") } footer: {
                FooterText("A MacBook with its lid closed and no external display will still sleep. A new server port applies after you quit and reopen InterLude.")
            }

            Section {
                Button("Export diagnostics…") { export() }
            } header: { Text("Diagnostics") } footer: {
                FooterText("Saves a zip of the event log, station list and profiles. Nothing is sent anywhere.")
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { stationID = model.selectedStationID; loadSlots() }
        .onChange(of: stationID) { loadSlots() }
    }

    private func loadSlots() { slots = model.profile(stationID).detector.slotMinutes.map(String.init).joined(separator: ", ") }

    private func commitSlots() {
        let mins = slots.split(whereSeparator: { ", ".contains($0) }).compactMap { Int($0) }.filter { (0..<60).contains($0) }
        guard !mins.isEmpty else { loadSlots(); return }
        model.updateProfile(stationID) { $0.detector.slotMinutes = mins }
        loadSlots()
    }

    private func export() {
        guard let folder = model.diagnosticsFolder() else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "InterLude-diagnostics.zip"
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        var err: NSError?
        NSFileCoordinator().coordinate(readingItemAt: folder, options: .forUploading, error: &err) { zip in
            try? FileManager.default.removeItem(at: dest)
            try? FileManager.default.copyItem(at: zip, to: dest)
        }
    }
}

private struct SliderRow: View {
    let title: String
    let value: Double
    let range: ClosedRange<Double>
    let step: Double
    let unit: String
    let onChange: (Double) -> Void

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 10) {
                Slider(value: Binding(get: { value }, set: { onChange($0.rounded()) }), in: range, step: step).frame(width: 180)
                Text("\(Int(value)) \(unit)").monospacedDigit().foregroundStyle(.secondary).frame(width: 56, alignment: .trailing)
            }
        }
    }
}

private struct FooterText: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
            .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
    }
}
