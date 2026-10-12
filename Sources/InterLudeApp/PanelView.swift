import SwiftUI
import InterLudeCore

struct PanelView: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 14) {
            if model.showWelcome && !model.demoHidesWelcome { WelcomeCard(dismiss: { model.showWelcome = false }) }
            if let e = model.errorText { ErrorBanner(model: model, text: e) }
            NowPlayingHeader(model: model)
            TransportRow(model: model)
            VStack(spacing: 8) {
                StationMenu(model: model)
                OutputMenu(model: model)
            }
            NewsCard(model: model)
            if model.isPlaying && !model.status.recentBlocks.isEmpty { RecentBlocks(model: model) }
            FooterRow(model: model, openSettings: {
                openWindow(id: "settings"); NSApp.activate(ignoringOtherApps: true)
            })
        }
        .padding(16)
        .frame(width: 340)
        .animation(.snappy(duration: 0.25), value: model.status.muted)
        .animation(.snappy(duration: 0.25), value: model.status.muteStartsIn == nil)
        .animation(.snappy(duration: 0.25), value: model.isPlaying)
        .animation(.snappy(duration: 0.25), value: model.errorText)
        .animation(.snappy(duration: 0.25), value: model.showWelcome)
    }
}

// MARK: Header

private struct NowPlayingHeader: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 12) {
            Artwork(url: model.isPlaying ? model.status.nowPlaying?.imageURL : nil,
                    station: model.selectedStation,
                    muted: model.isPlaying && model.status.muted)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    StatusBadge(state: badgeState)
                    Text(model.isPlaying || model.isStarting ? (model.selectedStation?.name ?? "") : (model.errorText != nil ? "Stopped" : "Not playing"))
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
                }
                Text(title).font(.headline).lineLimit(1)
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private var badgeState: StatusBadge.State {
        if model.isStarting { return .starting }
        if model.isPlaying { return model.status.muted ? .muted : .live }
        if model.errorText != nil { return .error }
        return .off
    }

    private var title: String {
        guard model.isPlaying else { return model.selectedStation?.name ?? "InterLude" }
        if model.status.muted { return "News muted" }
        return model.status.nowPlaying?.title ?? model.status.nowPlaying?.artist ?? model.selectedStation?.name ?? "Playing"
    }

    private var subtitle: String {
        if model.isStarting { return "Starting about a minute behind live…" }
        guard model.isPlaying else { return "Ready to play on \(model.selectedOutput.label)" }
        if model.status.muted { return "Sound returns when the music does" }
        if let np = model.status.nowPlaying, np.title != nil { return np.artist }
        return "On \(model.selectedOutput.label)"
    }
}

/// Album art when there is some, otherwise the station's badge.
struct Artwork: View {
    let url: URL?
    let station: Station?
    let muted: Bool
    var size: CGFloat = 68

    var body: some View {
        ZStack {
            StationBadge(station: station, size: size)
            if let url {
                AsyncImage(url: url, transaction: Transaction(animation: .easeIn(duration: 0.3))) { phase in
                    if let img = phase.image { img.resizable().scaledToFill().transition(.opacity) }
                }
            }
            if muted {
                Rectangle().fill(.black.opacity(0.55))
                Image(systemName: "speaker.slash.fill").font(.title2).foregroundStyle(.white)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.16, style: .continuous))
        .shadow(color: .black.opacity(0.2), radius: 5, y: 2)
    }
}

struct StationBadge: View {
    let station: Station?
    var size: CGFloat

    var body: some View {
        let base = Color(hex: station?.colour) ?? .accentColor
        ZStack {
            Rectangle().fill(LinearGradient(colors: [base, base.mix(with: .black, by: 0.35)], startPoint: .topLeading, endPoint: .bottomTrailing))
            Text(station?.short ?? String(station?.name.prefix(1) ?? "R"))
                .font(.system(size: size * 0.38, weight: .heavy, design: .rounded))
                .foregroundStyle(.white.opacity(0.95))
                .minimumScaleFactor(0.5)
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.16, style: .continuous))
    }
}

private struct StatusBadge: View {
    enum State { case off, starting, live, muted, error }
    let state: State
    @SwiftUI.State private var pulse = false

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
                .opacity(state == .starting && pulse ? 0.25 : 1)
            if let label { Text(label).font(.system(size: 9, weight: .bold)).foregroundStyle(color) }
        }
        .padding(.horizontal, label == nil ? 0 : 5).padding(.vertical, 2)
        .background(label == nil ? Color.clear : color.opacity(0.14), in: Capsule())
        .onAppear { withAnimation(.easeInOut(duration: 0.7).repeatForever()) { pulse = true } }
    }
    private var color: Color { switch state { case .off: .secondary; case .starting: .yellow; case .live: .green; case .muted: .orange; case .error: .red } }
    private var label: String? { switch state { case .live: "LIVE"; case .muted: "MUTED"; case .starting: "STARTING"; default: nil } }
}

// MARK: Transport

private struct TransportRow: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: 12) {
            Button { model.togglePlay() } label: {
                ZStack {
                    Circle().fill(Color.accentColor.gradient)
                    if model.isStarting { ProgressView().controlSize(.small).tint(.white) }
                    else {
                        Image(systemName: model.isPlaying ? "stop.fill" : "play.fill")
                            .font(.system(size: 17, weight: .bold)).foregroundStyle(.white)
                            .offset(x: model.isPlaying ? 0 : 1.5)
                            .contentTransition(.symbolEffect(.replace))
                    }
                }
                .frame(width: 46, height: 46)
                .shadow(color: Color.accentColor.opacity(0.35), radius: 6, y: 2)
            }
            .buttonStyle(PressableStyle())
            .keyboardShortcut(.space, modifiers: [])
            .accessibilityLabel(model.isPlaying || model.isStarting ? "Stop" : "Play")
            .help(model.isPlaying || model.isStarting ? "Stop (Space)" : "Play (Space)")

            Image(systemName: model.volume == 0 ? "speaker.slash.fill" : "speaker.fill")
                .foregroundStyle(.secondary).frame(width: 16)
                .onTapGesture { model.volume = model.volume == 0 ? 0.5 : 0 }
                .accessibilityLabel("Mute")
            Slider(value: $model.volume, in: 0...1).accessibilityLabel("Volume")
            Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary).frame(width: 22)
                .accessibilityHidden(true)
        }
    }
}

struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed ? 0.93 : 1).animation(.snappy(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: Pickers

private struct StationMenu: View {
    let model: AppModel

    var body: some View {
        Menu {
            if !model.favouriteStations.isEmpty {
                Section("Favourites") { ForEach(model.favouriteStations) { item($0) } }
                Section("All stations") { ForEach(model.otherStations) { item($0) } }
            } else {
                ForEach(model.stations) { item($0) }
            }
            Divider()
            let fav = model.profile(model.selectedStationID).favourite
            Button {
                model.updateProfile(model.selectedStationID) { $0.favourite.toggle() }
            } label: {
                Label(fav ? "Remove \(model.selectedStation?.name ?? "") from favourites" : "Add \(model.selectedStation?.name ?? "") to favourites",
                      systemImage: fav ? "star.slash" : "star")
            }
        } label: {
            Chip(caption: "Station", text: model.selectedStation?.name ?? "Choose a station",
                 leading: AnyView(StationBadge(station: model.selectedStation, size: 20)),
                 trailingIcon: model.profile(model.selectedStationID).favourite ? "star.fill" : nil)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
        .accessibilityLabel("Station: \(model.selectedStation?.name ?? "none")")
    }

    private func item(_ s: Station) -> some View {
        Button { model.switchStation(to: s.serviceId) } label: {
            if s.serviceId == model.selectedStationID { Label(s.name, systemImage: "checkmark") } else { Text(s.name) }
        }
    }
}

private struct OutputMenu: View {
    let model: AppModel

    var body: some View {
        let speakers = model.outputs.filter { if case .cast(let d) = $0 { !d.isGroup } else { false } }
        let groups = model.outputs.filter { if case .cast(let d) = $0 { d.isGroup } else { false } }
        Menu {
            item(.thisMac)
            if !speakers.isEmpty { Section("Speakers") { ForEach(speakers) { item($0) } } }
            if !groups.isEmpty { Section("Groups") { ForEach(groups) { item($0) } } }
            switch model.discoveryState {
            case .searching: Text("Looking for speakers…")
            case .denied: Text("Allow Local Network for InterLude in System Settings › Privacy & Security to find speakers")
            case .ready: if speakers.isEmpty && groups.isEmpty { Text("No Chromecast speakers found") }
            }
        } label: {
            Chip(caption: model.isPlaying ? "Playing on" : "Play on", text: model.selectedOutput.label,
                 leading: AnyView(Image(systemName: model.selectedOutput.icon).font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 20)),
                 trailingIcon: nil)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
        .accessibilityLabel("Output: \(model.selectedOutput.label)")
    }

    private func item(_ o: Output) -> some View {
        Button { model.switchOutput(to: o.id) } label: {
            Label(o.detail.map { "\(o.label)  ·  \($0)" } ?? o.label, systemImage: o.id == model.selectedOutputID ? "checkmark" : o.icon)
        }
    }
}

private struct Chip: View {
    let caption: String
    let text: String
    let leading: AnyView
    let trailingIcon: String?
    @State private var hover = false

    var body: some View {
        HStack(spacing: 9) {
            leading
            VStack(alignment: .leading, spacing: 0) {
                Text(caption).font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary).textCase(.uppercase)
                Text(text).font(.callout).lineLimit(1)
            }
            Spacer(minLength: 0)
            if let trailingIcon { Image(systemName: trailingIcon).font(.caption2).foregroundStyle(.yellow) }
            Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 10).frame(height: 38)
        .frame(maxWidth: .infinity)
        .background(.quaternary.opacity(hover ? 0.8 : 0.5), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }
}

// MARK: News

private struct NewsCard: View {
    let model: AppModel

    var body: some View {
        let p = model.profile(model.selectedStationID)
        let speech = model.selectedStation?.kind == .speech
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: p.muteNews && !speech ? "newspaper.fill" : "newspaper")
                    .font(.title3).foregroundStyle(p.muteNews && !speech ? Color.accentColor : .secondary).frame(width: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Mute news").font(.callout.weight(.medium))
                    Text(model.muteSubtitle).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Toggle("Mute news", isOn: Binding(get: { p.muteNews && !speech },
                                                  set: { v in model.updateProfile(model.selectedStationID) { $0.muteNews = v } }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    .disabled(speech)
            }
            .padding(12)

            if model.isPlaying && !speech {
                if model.status.muted {
                    HStack(spacing: 10) {
                        Image(systemName: "speaker.slash.fill").foregroundStyle(.orange).symbolEffect(.pulse)
                        VStack(alignment: .leading, spacing: 0) {
                            Text("Bulletin muted").font(.callout.weight(.semibold))
                            if let e = model.status.muteElapsed { Text("\(clock(e)) so far").font(.caption).foregroundStyle(.secondary).monospacedDigit() }
                        }
                        Spacer()
                        Button("Not news") { model.notNews() }
                            .buttonStyle(.borderedProminent).tint(.orange).controlSize(.small)
                            .help("This isn't a bulletin. Sound returns within a few seconds.")
                    }
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .background(Color.orange.opacity(0.13))
                    .transition(.opacity.combined(with: .move(edge: .top)))
                } else if let t = model.status.muteStartsIn {
                    HStack(spacing: 8) {
                        Image(systemName: "timer").foregroundStyle(.orange)
                        Text("Bulletin coming up · muting in \(clock(t))").font(.caption.weight(.medium)).monospacedDigit()
                        Spacer()
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Color.orange.opacity(0.08))
                    .transition(.opacity)
                }
                Divider().padding(.horizontal, 12).opacity(model.status.muted || model.status.muteStartsIn != nil ? 0 : 1)
                HStack {
                    Button { model.thatWasNews() } label: { Label("News got through", systemImage: "exclamationmark.bubble") }
                        .buttonStyle(.borderless).controlSize(.small)
                        .help("Press after a bulletin that wasn't muted. InterLude learns the station's news jingle from three of these.")
                    Spacer()
                    if let learned = model.learnedNote { Text(learned).font(.caption2).foregroundStyle(.secondary) }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
            }
        }
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

func clock(_ seconds: Double) -> String {
    let s = max(0, Int(seconds.rounded()))
    return "\(s / 60):" + String(format: "%02d", s % 60)
}

// MARK: Recent

private struct RecentBlocks: View {
    @Bindable var model: AppModel

    var body: some View {
        let blocks = model.status.recentBlocks
        VStack(alignment: .leading, spacing: 7) {
            Button { withAnimation(.snappy) { model.showRecent.toggle() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right").font(.caption2.weight(.bold)).rotationEffect(.degrees(model.showRecent ? 90 : 0))
                    Text("Recent mutes").font(.caption.weight(.semibold))
                    Text("\(blocks.filter { !$0.falseStart }.count)").font(.caption2.monospacedDigit())
                        .padding(.horizontal, 5).background(.quaternary, in: Capsule())
                    Spacer()
                }
                .foregroundStyle(.secondary).contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if model.showRecent {
                VStack(spacing: 5) {
                    ForEach(blocks.prefix(6)) { b in row(b) }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private func row(_ b: NewsBlock) -> some View {
        HStack(spacing: 8) {
            Image(systemName: b.falseStart ? "arrow.uturn.backward.circle.fill" : (b.isOpen ? "speaker.slash.circle.fill" : "checkmark.circle.fill"))
                .foregroundStyle(b.falseStart ? Color.secondary : (b.isOpen ? Color.orange : Color.green))
            Text(time(b.start)).font(.caption.monospacedDigit())
            Text(length(b)).font(.caption).foregroundStyle(.secondary)
            Spacer()
            if b.falseStart { Text("Not news").font(.caption2).foregroundStyle(.tertiary) }
            else if !b.isOpen {
                Button("Wasn't news") { model.markWrong(b.id) }.buttonStyle(.borderless).font(.caption2)
                    .help("Marks this as a mistake so InterLude can be tuned")
            }
        }
    }

    private func time(_ t: Double) -> String { Date(timeIntervalSince1970: t).formatted(date: .omitted, time: .shortened) }
    private func length(_ b: NewsBlock) -> String {
        guard let e = b.end else { return "muting now" }
        let s = Int(e - b.start)
        return s >= 60 ? "\(s / 60) min \(s % 60) s" : "\(s) s"
    }
}

// MARK: Footer, welcome and errors

private struct FooterRow: View {
    let model: AppModel
    let openSettings: () -> Void
    var body: some View {
        HStack {
            Button(action: openSettings) { Image(systemName: "gearshape") }
                .buttonStyle(.borderless).help("Settings (⌘,)").keyboardShortcut(",", modifiers: .command)
                .accessibilityLabel("Settings")
            Spacer()
            if model.isPlaying {
                Text("\(model.delayDescription) behind live").font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
            }
            Spacer()
            Button { NSApplication.shared.terminate(nil) } label: { Image(systemName: "power") }
                .buttonStyle(.borderless).help("Quit InterLude (⌘Q)").keyboardShortcut("q", modifiers: .command)
                .accessibilityLabel("Quit")
        }
        .foregroundStyle(.secondary)
    }
}

private struct WelcomeCard: View {
    let dismiss: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 26, height: 26)
                Text("Welcome to InterLude").font(.callout.weight(.semibold))
            }
            Text("Pick a station and a speaker, then press play. InterLude plays about a minute behind live, so it can hear each news bulletin coming and silence it for you.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 4) {
                Text("It lives in the menu bar:").font(.caption).foregroundStyle(.secondary)
                Image(systemName: "radio").font(.caption)
                Spacer()
                Button("Got it", action: dismiss).controlSize(.small).keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
        .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}

private struct ErrorBanner: View {
    let model: AppModel
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                Text(text).font(.caption).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button { model.errorText = nil; model.castFailed = false; model.stationFailed = false } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).font(.caption2).accessibilityLabel("Dismiss")
            }
            if model.castFailed || model.stationFailed {
                HStack(spacing: 8) {
                    Spacer()
                    if model.castFailed { Button("Play on this Mac") { model.playOnThisMac() }.controlSize(.small) }
                    Button("Try again") { model.start() }.controlSize(.small).buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(10)
        .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}

extension Color {
    init?(hex: String?) {
        guard var h = hex?.trimmingCharacters(in: .whitespaces) else { return nil }
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}
