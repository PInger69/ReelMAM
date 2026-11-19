import AVKit
import StadaMAMCore
import SwiftUI

/// Everything stored about one clip, loaded together so the player and inspector agree.
struct ClipData {
    var markers: [Marker] = []
    var transcript: [TranscriptSegment] = []
    var tags: [SceneTag] = []
    var faces: [FaceSighting] = []
    var proxies: [ProxyRecord] = []
}

struct ClipDetailView: View {
    @Environment(AppModel.self) private var model
    let asset: Asset
    @State private var player = PlayerController()
    @State private var data = ClipData()
    @FocusState private var playerFocused: Bool

    var body: some View {
        VSplitView {
            VStack(spacing: 0) {
                viewer
                ScrubBar(player: player, thumbnails: model.thumbnailPaths[asset.id] ?? [],
                         markers: data.markers, shots: data.tags.filter { $0.kind == .shot })
                    .frame(height: 46)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                TransportBar(asset: asset, player: player)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }
            .background(Color.black.opacity(0.35))
            .frame(minHeight: 320)
            .focusable()
            .focusEffectDisabled()
            .focused($playerFocused)
            .onKeyPress(phases: .down) { handle($0) }

            InspectorView(asset: asset, data: data, player: player)
                .frame(minHeight: 200)
        }
        .navigationTitle(asset.fileName)
        .navigationSubtitle(asset.sourcePath)
        .toolbar {
            ToolbarItem {
                Menu {
                    AssetActions(asset: asset)
                } label: {
                    Label("Clip", systemImage: "ellipsis.circle")
                }
            }
        }
        .task(id: model.revision) { refresh() }
        .onChange(of: model.pendingSeekSeconds, initial: true) { _, seconds in
            guard let seconds else { return }
            player.seek(toSeconds: seconds)
            model.pendingSeekSeconds = nil
        }
        .onAppear { playerFocused = true }
        .onDisappear { player.pause() }
    }

    @ViewBuilder private var viewer: some View {
        ZStack {
            Color.black
            if player.hasMedia {
                PlayerSurface(player: player.player)
            } else {
                ContentUnavailableView {
                    Label("No playable media", systemImage: "play.slash")
                } description: {
                    Text(asset.decodePath.canRender
                         ? "This format needs a proxy to play. Generate one from the Clip menu."
                         : "\(asset.formatName) is catalogued and searchable, but playing it needs the camera maker's SDK, which is not installed yet.")
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { playerFocused = true }
    }

    private func refresh() {
        let catalog = model.catalog
        data = ClipData(
            markers: (try? catalog.markers(forAsset: asset.id)) ?? [],
            transcript: (try? catalog.transcript(forAsset: asset.id)) ?? [],
            tags: (try? catalog.tags(forAsset: asset.id)) ?? [],
            faces: (try? catalog.faces(forAsset: asset.id)) ?? [],
            proxies: (try? catalog.proxies(forAsset: asset.id)) ?? [])
        player.load(path: model.library?.playablePath(for: asset), frameRate: asset.frameRate,
                    durationFrames: asset.durationFrames)
    }

    /// Editor-standard keys: Space play/pause, J K L shuttle, arrows step, I / O mark, M marker.
    private func handle(_ press: KeyPress) -> KeyPress.Result {
        let big = press.modifiers.contains(.shift) ? 10 : 1
        switch press.key {
        case .space: player.togglePlay()
        case .leftArrow: player.step(frames: -big)
        case .rightArrow: player.step(frames: big)
        case .home: player.seek(toSeconds: 0)
        case .end: player.seek(toFrame: max(asset.durationFrames - 1, 0))
        default:
            switch press.characters.lowercased() {
            case "j": player.shuttle(forward: false)
            case "k": player.pause()
            case "l": player.shuttle(forward: true)
            case "i": press.modifiers.contains(.shift) ? player.goToIn() : player.markIn()
            case "o": press.modifiers.contains(.shift) ? player.goToOut() : player.markOut()
            case "x": player.clearMarks()
            case "m": model.addMarker(to: asset, inFrame: player.currentFrame, outFrame: nil)
            default: return .ignored
            }
        }
        return .handled
    }
}

struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}

/// Filmstrip scrub bar: drag anywhere to scrub; shows the marked range, markers and shot cuts.
struct ScrubBar: View {
    let player: PlayerController
    let thumbnails: [String]
    let markers: [Marker]
    let shots: [SceneTag]

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let duration = max(player.durationSeconds, 0.001)
            let lastFrame = CGFloat(max(player.durationFrames - 1, 1))
            ZStack(alignment: .leading) {
                HStack(spacing: 0) {
                    ForEach(thumbnails, id: \.self) { path in
                        if let image = ThumbnailCache.image(atPath: path) {
                            Image(nsImage: image)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: width / CGFloat(thumbnails.count), height: proxy.size.height)
                                .clipped()
                        }
                    }
                }
                .opacity(0.55)
                .background(Color.white.opacity(0.06))

                ForEach(shots.dropFirst()) { shot in
                    Rectangle()
                        .fill(Color.white.opacity(0.45))
                        .frame(width: 1)
                        .offset(x: CGFloat(shot.startSeconds / duration) * width)
                }
                if let start = player.inFrame ?? (player.outFrame == nil ? nil : 0) {
                    let end = player.outFrame ?? player.durationFrames - 1
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.35))
                        .overlay(Rectangle().strokeBorder(Color.accentColor, lineWidth: 1.5))
                        .frame(width: max(CGFloat(end - start + 1) / (lastFrame + 1) * width, 2))
                        .offset(x: CGFloat(start) / (lastFrame + 1) * width)
                }
                ForEach(markers) { marker in
                    Circle()
                        .fill(marker.isSubclip ? Color.orange : Color.cyan)
                        .frame(width: 7, height: 7)
                        .offset(x: CGFloat(marker.inFrame) / (lastFrame + 1) * width - 3.5,
                                y: -proxy.size.height / 2 + 5)
                }
                Rectangle()
                    .fill(Color.white)
                    .frame(width: 2)
                    .shadow(color: .black, radius: 2)
                    .offset(x: CGFloat(player.currentSeconds / duration) * width - 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                player.pause()
                player.seek(toSeconds: Double(min(max(value.location.x / width, 0), 1)) * duration)
            })
        }
    }
}

struct TransportBar: View {
    @Environment(AppModel.self) private var model
    let asset: Asset
    let player: PlayerController

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 1) {
                Text(asset.timecode(atFrame: player.currentFrame).description)
                    .font(.system(size: 20, weight: .semibold, design: .monospaced))
                Text("Frame \(player.currentFrame)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .fixedSize()

            Spacer(minLength: 0)

            HStack(spacing: 4) {
                control("backward.end.fill", "Go to in point (⇧I)") { player.goToIn() }
                control("backward.frame.fill", "Back one frame (←)") { player.step(frames: -1) }
                control("backward.fill", "Shuttle reverse (J)") { player.shuttle(forward: false) }
                Button { player.togglePlay() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 18))
                        .frame(width: 40, height: 32)
                }
                .buttonStyle(.borderedProminent)
                .help("Play / pause (Space)")
                control("forward.fill", "Shuttle forward (L)") { player.shuttle(forward: true) }
                control("forward.frame.fill", "Forward one frame (→)") { player.step(frames: 1) }
                control("forward.end.fill", "Go to out point (⇧O)") { player.goToOut() }
            }
            if abs(player.rate) > 1 || player.rate < 0 {
                Text("\(player.rate < 0 ? "−" : "")\(Int(abs(player.rate)))×")
                    .font(.caption.monospacedDigit().weight(.bold))
                    .foregroundStyle(Color.accentColor)
            }

            Spacer(minLength: 0)

            HStack(spacing: 6) {
                Button("In") { player.markIn() }.help("Mark in (I)").fixedSize()
                Button("Out") { player.markOut() }.help("Mark out (O)").fixedSize()
                Button { player.clearMarks() } label: { Image(systemName: "xmark") }
                    .help("Clear marks (X)")
                    .disabled(player.inFrame == nil && player.outFrame == nil)
                Button { model.addMarker(to: asset, inFrame: player.currentFrame, outFrame: nil) } label: {
                    Image(systemName: "bookmark.fill")
                }
                .help("Add marker (M)")
                Button {
                    model.addMarker(to: asset, inFrame: player.inFrame ?? 0,
                                    outFrame: player.outFrame ?? asset.durationFrames - 1)
                } label: {
                    Image(systemName: "scissors")
                }
                .help("Save the marked range as a subclip")
                .disabled(player.inFrame == nil && player.outFrame == nil)
            }
            .controlSize(.small)

            VStack(alignment: .trailing, spacing: 1) {
                if let marked = player.markedDurationFrames {
                    Text(Timecode(frames: marked, rate: asset.frameRate).description)
                        .font(.callout.monospacedDigit().weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                    Text("Marked").font(.caption2).foregroundStyle(.secondary)
                } else {
                    Text(Timecode(frames: asset.durationFrames, rate: asset.frameRate).description)
                        .font(.callout.monospacedDigit())
                    Text("Duration").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .fixedSize()
        }
    }

    private func control(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 26, height: 24)
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}
