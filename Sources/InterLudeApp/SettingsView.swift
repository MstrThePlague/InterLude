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
            Section("Station") {
                Picker("Station", selection: $stationID) {
                    ForEach(model.orderedStations) { Text($0.name).tag($0.serviceId) }
                }
                if station != nil {
                    let p = model.profile(stationID)
                    LabeledContent("Delay behind live") {
                        HStack {
                            Slider(value: Binding(get: { p.delaySeconds }, set: { v in model.updateProfile(stationID) { $0.delaySeconds = v.rounded() } }), in: 30...600, step: 5)
                            Text("\(Int(p.delaySeconds)) s").monospacedDigit().frame(width: 52, alignment: .trailing)
                        }
                    }
                    LabeledContent("Longest mute") {
                        HStack {
                            Slider(value: Binding(get: { p.detector.maxMuteSeconds / 60 }, set: { v in model.updateProfile(stationID) { $0.detector.maxMuteSeconds = v.rounded() * 60 } }), in: 3...20, step: 1)
                            Text("\(Int(p.detector.maxMuteSeconds / 60)) min").monospacedDigit().frame(width: 52, alignment: .trailing)
                        }
                    }
                    Toggle("Shadow mode (log bulletins, never mute)", isOn: Binding(get: { p.shadowMode }, set: { v in model.updateProfile(stationID) { $0.shadowMode = v } }))
                    Toggle("Mute only on the news ident", isOn: Binding(get: { p.detector.identOnly }, set: { v in model.updateProfile(stationID) { $0.detector.identOnly = v } }))
                    TextField("Bulletin slots (minutes past the hour)", text: $slots)
                        .onSubmit { commitSlots() }
                    Text("Changes to delay and slots apply the next time you press Play.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("General") {
                Picker("Bitrate", selection: $model.bitrate) { Text("128 kbps").tag(128_000); Text("320 kbps").tag(320_000) }
                TextField("Server port", value: $model.port, format: .number.grouping(.never))
                Toggle("Keep Mac awake while playing", isOn: $model.keepAwake)
                Text("A MacBook with its lid closed and no external display will still sleep and stop playback.").font(.caption).foregroundStyle(.secondary)
                Toggle("Start at login", isOn: Binding(get: { model.startAtLogin }, set: { model.setStartAtLogin($0) }))
            }
            Section("Diagnostics") {
                Button("Export diagnostics…") { export() }
                Text("Zips the event log, station list and profiles. Nothing is sent anywhere.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .padding(.bottom, 8)
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
