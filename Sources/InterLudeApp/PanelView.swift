import SwiftUI
import InterLudeCore

struct PanelView: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var showRecent = false

    var body: some View {
        VStack(spacing: 14) {
            if let e = model.errorText { ErrorBanner(text: e, retry: model.stationFailed ? { model.start() } : nil, dismiss: { model.errorText = nil }) }
            NowPlayingHeader(model: model)
            TransportRow(model: model)
            PickerRow(model: model)
            NewsCard(model: model)
            if model.isPlaying { RecentBlocks(model: model, expanded: $showRecent) }
            FooterRow(model: model, openSettings: { openWindow(id: "settings"); NSApp.activate(ignoringOtherApps: true) })
        }
        .padding(16)
        .frame(width: 340)
        .animation(.snappy(duration: 0.25), value: model.status.muted)
        .animation(.snappy(duration: 0.25), value: model.isPlaying)
        .animation(.snappy(duration: 0.25), value: model.errorText)
    }
}

// MARK: Header

private struct NowPlayingHeader: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 12) {
            Artwork(url: model.isPlaying ? model.status.nowPlaying?.imageURL : nil, muted: model.isPlaying && model.status.muted,
                    initial: String(model.selectedStation?.name.prefix(1) ?? "R"))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    StatusDot(state: dotState)
                    Text(model.selectedStation?.name ?? "InterLude").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
                Text(titleText).font(.headline).lineLimit(1)
                Text(subtitleText).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    private var dotState: StatusDot.State {
        if model.errorText != nil && !model.isPlaying { return .error }
        if model.isStarting { return .starting }
        if model.isPlaying { return model.status.muted ? .muted : .live }
        return .off
    }

    private var titleText: String {
        if model.isStarting { return "Starting…" }
        guard model.isPlaying else { return "Not playing" }
        if model.status.muted { return "News muted" }
        return model.status.nowPlaying?.title ?? model.status.nowPlaying?.artist ?? "Playing"
    }

    private var subtitleText: String {
        guard model.isPlaying else { return model.selectedOutput.label }
        if model.status.muted { return "Sound returns when the bulletin ends" }
        if let np = model.status.nowPlaying, np.title != nil { return np.artist }
        return "\(model.delayDescription) behind live"
    }
}

private struct Artwork: View {
    let url: URL?
    let muted: Bool
    let initial: String

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(LinearGradient(colors: [.accentColor.opacity(0.85), .accentColor.opacity(0.45)], startPoint: .topLeading, endPoint: .bottomTrailing))
            Text(initial).font(.system(size: 26, weight: .bold, design: .rounded)).foregroundStyle(.white.opacity(0.9))
            if let url {
                AsyncImage(url: url) { phase in
                    if let img = phase.image { img.resizable().scaledToFill().transition(.opacity) }
                }
            }
            if muted {
                Rectangle().fill(.black.opacity(0.55))
                Image(systemName: "speaker.slash.fill").font(.title2).foregroundStyle(.white)
            }
        }
        .frame(width: 64, height: 64)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
    }
}

private struct StatusDot: View {
    enum State { case off, starting, live, muted, error }
    let state: State
    @SwiftUI.State private var pulse = false

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
                .opacity(state == .starting && pulse ? 0.3 : 1)
                .animation(state == .starting ? .easeInOut(duration: 0.7).repeatForever() : .default, value: pulse)
            if let label { Text(label).font(.caption2.weight(.bold)).foregroundStyle(color) }
        }
        .onAppear { pulse = true }
    }
    private var color: Color { switch state { case .off: .secondary; case .starting: .yellow; case .live: .green; case .muted: .orange; case .error: .red } }
    private var label: String? { switch state { case .live: "LIVE"; case .muted: "MUTED"; default: nil } }
}

// MARK: Transport

private struct TransportRow: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: 12) {
            Button { model.togglePlay() } label: {
                ZStack {
                    Circle().fill(Color.accentColor)
                    if model.isStarting { ProgressView().controlSize(.small).tint(.white) }
                    else { Image(systemName: model.isPlaying ? "stop.fill" : "play.fill").font(.system(size: 17, weight: .bold)).foregroundStyle(.white).offset(x: model.isPlaying ? 0 : 1) }
                }
                .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.space, modifiers: [])
            .help(model.isPlaying || model.isStarting ? "Stop" : "Play")

            Image(systemName: model.volume == 0 ? "speaker.fill" : "speaker.wave.1.fill").foregroundStyle(.secondary).frame(width: 18)
            Slider(value: $model.volume, in: 0...1)
            Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary).frame(width: 20)
        }
    }
}

// MARK: Pickers

private struct PickerRow: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) { stationMenu; favouriteButton }
            outputMenu
        }
    }

    private var stationMenu: some View {
            Menu {
                ForEach(model.orderedStations) { s in
                    Button {
                        model.switchStation(to: s.serviceId)
                    } label: {
                        Label((model.profile(s.serviceId).favourite ? "★ " : "") + s.name, systemImage: s.serviceId == model.selectedStationID ? "checkmark" : "")
                    }
                }
            } label: { Chip(icon: "dot.radiowaves.left.and.right", text: model.selectedStation?.name ?? "Station") }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
    }

    private var favouriteButton: some View {
            Button {
                let id = model.selectedStationID
                model.updateProfile(id) { $0.favourite.toggle() }
            } label: {
                Image(systemName: model.profile(model.selectedStationID).favourite ? "star.fill" : "star")
                    .foregroundStyle(model.profile(model.selectedStationID).favourite ? Color.yellow : Color.secondary)
                    .frame(width: 30, height: 30)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain).help("Favourite")
    }

    private var outputMenu: some View {
            Menu {
                ForEach(model.outputs) { o in
                    Button { model.selectedOutputID = o.id } label: {
                        Label(o.label, systemImage: o.id == model.selectedOutputID ? "checkmark" : "")
                    }
                }
            } label: { Chip(icon: model.selectedOutput.icon, text: model.selectedOutput.label) }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
            .disabled(model.isPlaying || model.isStarting)
            .help(model.isPlaying ? "Stop to change the output" : "Where to play")
    }
}

private struct Chip: View {
    let icon: String
    let text: String
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.caption).foregroundStyle(.secondary)
            Text(text).font(.callout).lineLimit(1)
            Spacer(minLength: 0)
            Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 10).frame(height: 30)
        .frame(maxWidth: .infinity)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
    }
}

// MARK: News

private struct NewsCard: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "newspaper").font(.title3).foregroundStyle(.secondary).frame(width: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Mute news").font(.callout.weight(.medium))
                    Text(model.muteSubtitle).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Toggle("", isOn: Binding(get: { model.profile(model.selectedStationID).muteNews },
                                         set: { v in model.updateProfile(model.selectedStationID) { $0.muteNews = v } }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    .disabled(model.selectedStation?.kind == .speech)
            }
            .padding(12)

            if model.isPlaying {
                Divider().padding(.horizontal, 12)
                if model.status.muted {
                    HStack(spacing: 10) {
                        Image(systemName: "speaker.slash.fill").foregroundStyle(.orange)
                        Text(muteText).font(.callout.weight(.medium)).monospacedDigit()
                        Spacer()
                        Button("Not news") { model.notNews() }
                            .buttonStyle(.borderedProminent).tint(.orange).controlSize(.small)
                            .help("This was not a bulletin. Sound returns within a few seconds.")
                    }
                    .padding(12)
                    .background(Color.orange.opacity(0.12))
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
                HStack {
                    Button { model.thatWasNews() } label: { Label("That was news", systemImage: "hand.thumbsup") }
                        .buttonStyle(.borderless).controlSize(.small)
                        .help("A bulletin got through. InterLude learns from it.")
                    Spacer()
                    if let learned = model.learnedNote { Text(learned).font(.caption2).foregroundStyle(.secondary) }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
            }
        }
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var muteText: String {
        guard let e = model.status.muteElapsed else { return "News muted" }
        return "News muted · \(Int(e) / 60):" + String(format: "%02d", Int(e) % 60)
    }
}

// MARK: Recent

private struct RecentBlocks: View {
    let model: AppModel
    @Binding var expanded: Bool

    var body: some View {
        let blocks = model.status.recentBlocks
        VStack(alignment: .leading, spacing: 6) {
            Button { withAnimation(.snappy) { expanded.toggle() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right").font(.caption2.weight(.bold)).rotationEffect(.degrees(expanded ? 90 : 0))
                    Text("Recent bulletins").font(.caption.weight(.semibold))
                    Text("\(blocks.count)").font(.caption2).padding(.horizontal, 5).background(.quaternary, in: Capsule())
                    Spacer()
                }
                .foregroundStyle(.secondary).contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                if blocks.isEmpty {
                    Text("None yet. Muted bulletins appear here.").font(.caption).foregroundStyle(.tertiary)
                } else {
                    ForEach(blocks.prefix(6)) { b in
                        HStack(spacing: 8) {
                            Image(systemName: b.falseStart ? "xmark.circle.fill" : (b.isOpen ? "speaker.slash.fill" : "checkmark.circle.fill"))
                                .foregroundStyle(b.falseStart ? Color.red : (b.isOpen ? Color.orange : Color.green)).font(.caption)
                            Text(describe(b)).font(.caption.monospacedDigit())
                            if b.doubtful && !b.falseStart { Text("short").font(.caption2).foregroundStyle(.secondary) }
                            Spacer()
                            if b.falseStart { Text("Marked wrong").font(.caption2).foregroundStyle(.secondary) }
                            else if !b.isOpen { Button("Wrong") { model.markWrong(b.id) }.buttonStyle(.borderless).font(.caption) }
                        }
                    }
                }
            }
        }
    }

    private func describe(_ b: NewsBlock) -> String {
        let f = DateFormatter(); f.timeStyle = .short
        let t = f.string(from: Date(timeIntervalSince1970: b.start))
        guard let e = b.end else { return "\(t) · muting now" }
        let s = Int(e - b.start)
        return s >= 60 ? "\(t) · \(s / 60) min \(s % 60) s" : "\(t) · \(s) s"
    }
}

// MARK: Footer and errors

private struct FooterRow: View {
    let model: AppModel
    let openSettings: () -> Void
    var body: some View {
        HStack {
            Button(action: openSettings) { Image(systemName: "gearshape") }.buttonStyle(.borderless).help("Settings")
            Spacer()
            Text(model.isPlaying ? model.footerText : "").font(.caption2).foregroundStyle(.tertiary)
            Spacer()
            Button { NSApplication.shared.terminate(nil) } label: { Image(systemName: "power") }.buttonStyle(.borderless).help("Quit InterLude")
        }
        .foregroundStyle(.secondary)
    }
}

private struct ErrorBanner: View {
    let text: String
    let retry: (() -> Void)?
    let dismiss: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            Text(text).font(.caption).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            VStack(spacing: 4) {
                if let retry { Button("Try again", action: retry).controlSize(.small) }
                Button { dismiss() } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).font(.caption2)
            }
        }
        .padding(10)
        .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}
