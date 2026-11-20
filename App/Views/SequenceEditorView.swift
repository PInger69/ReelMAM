import AVFoundation
import StradaMAMCore
import StradaMAMMedia
import SwiftUI

/// The cut screen. Three ways to work, none of which needs in and out points:
/// hold Keep while a clip plays; pick sentences from the clip's words; and arrange the result as a
/// storyboard of picture cards. Timecode and frame controls sit behind the Fine tune switch.
struct SequenceEditorView: View {
    enum Showing { case clip, cut }

    @Environment(AppModel.self) private var model
    @Environment(CutsModel.self) private var cuts
    let sequence: ResolvedSequence
    @State private var clipPlayer = PlayerController()
    @State private var cutPlayer = PlayerController()
    @State private var showing = Showing.cut
    @State private var transcript: [TranscriptSegment] = []
    @State private var chosenWords: Set<String> = []
    @State private var lastWord: String?
    /// Set while Keep is held: where the clip was when it went down, and whether it was playing.
    @State private var hold: (pressFrame: Int, wasPlaying: Bool)?
    @State private var notice: String?
    @FocusState private var viewerFocused: Bool

    private var clip: Asset? { model.selectedAsset }
    private var selectedCut: PlacedCut? { sequence.cuts.first { $0.id == cuts.selectedCutID } }
    private var showsClip: Bool { showing == .clip && clip != nil }

    var body: some View {
        VSplitView {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    if clip != nil, !sequence.cuts.isEmpty { showingPicker }
                    viewer
                    if showsClip, let clip { clipControls(clip) } else { cutControls }
                }
                if showsClip, let clip, !transcript.isEmpty {
                    Divider()
                    WordsPanel(asset: clip, transcript: transcript, player: clipPlayer, chosen: $chosenWords,
                               lastWord: $lastWord) { addChosenWords(from: clip) }
                        .frame(width: 300)
                }
            }
            .background(Color.black.opacity(0.35))
            .frame(minHeight: 340)
            .focusable()
            .focusEffectDisabled()
            .focused($viewerFocused)
            .onKeyPress(phases: .all) { handle($0) }

            VStack(spacing: 0) {
                if let progress = cuts.packageProgress { packageBar(progress) }
                Storyboard(sequence: sequence, onPlayAll: playAll, onPlayFrom: play(from:), onDropWords: dropWords)
                if cuts.fineTune, let cut = selectedCut {
                    Divider()
                    CutTrimBar(sequence: sequence, placed: cut, player: cutPlayer)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                }
            }
            .frame(minHeight: 230)
        }
        .navigationTitle(sequence.sequence.name)
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItemGroup {
                Toggle(isOn: Binding(get: { cuts.looksEnabled }, set: { cuts.looksEnabled = $0 })) {
                    Label("Rec.709 Look", systemImage: "camera.filters")
                }
                .help("Show log footage with normal contrast and colour. The files are not changed.")
                Menu {
                    Section("Timeline, linked to the camera originals") {
                        ForEach(SequenceTimelineFormat.allCases, id: \.self) { format in
                            Button(format.displayName + "…") { cuts.exportTimeline(format) }
                        }
                    }
                    Section("For a full editor") {
                        Button("Package with Camera Originals…") { cuts.exportPackage() }
                            .disabled(cuts.packageProgress != nil)
                    }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .help("Send this cut to Final Cut Pro, DaVinci Resolve or Premiere Pro")
                .disabled(sequence.cuts.isEmpty)
                Button("Done") { cuts.showsEditor = false }
                    .help("Go back to the clip view. The cut is saved as you go.")
            }
        }
        .task(id: cuts.revision) { await prepareCut() }
        .task(id: "\(clip?.id ?? "") \(model.revision) \(cuts.revision)") { prepareClip() }
        .onChange(of: model.selectedID) {
            // A clip picked from the library opens here, ready to keep parts of.
            cutPlayer.pause()
            chosenWords = []
            lastWord = nil
            notice = nil
            showing = .clip
        }
        .onChange(of: showing) {
            clipPlayer.pause()
            cutPlayer.pause()
        }
        .onAppear {
            showing = sequence.cuts.isEmpty && clip != nil ? .clip : .cut
            viewerFocused = true
        }
        .onDisappear {
            clipPlayer.pause()
            cutPlayer.pause()
        }
    }

    private var subtitle: String {
        let count = sequence.cuts.count
        let plain = "\(count) part\(count == 1 ? "" : "s")  ·  \(PlainLength.text(seconds: sequence.durationSeconds))"
        return cuts.fineTune ? plain + "  ·  \(PictureFormat.rateLabel(sequence.frameRate.fps)) fps" : plain
    }

    // MARK: Viewer

    private var showingPicker: some View {
        Picker("Showing", selection: $showing) {
            Text(clip?.fileName ?? "Clip").tag(Showing.clip)
            Text("Your cut").tag(Showing.cut)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: 420)
        .padding(.top, 8)
        .help("Watch the clip you picked, or the cut you have built")
    }

    @ViewBuilder private var viewer: some View {
        ZStack {
            Color.black
            if showsClip, let clip {
                if clipPlayer.hasMedia {
                    PlayerSurface(player: clipPlayer.player)
                } else {
                    ContentUnavailableView {
                        Label("This clip cannot be played yet", systemImage: "play.slash")
                    } description: {
                        Text(clip.decodePath.canRender
                             ? "It needs a proxy first. Make one from the clip's menu in the library."
                             : "\(clip.formatName) has no picture here yet, so parts of it cannot be kept by eye.")
                    }
                }
            } else if sequence.cuts.isEmpty {
                ContentUnavailableView {
                    Label("Nothing in this cut yet", systemImage: "rectangle.stack.badge.plus")
                } description: {
                    Text("Pick a clip from the library, then hold Keep while the part you want plays.")
                }
            } else {
                PlayerSurface(player: cutPlayer.player)
                if let cut = sequence.cut(atFrame: cutPlayer.currentFrame), model.library?.playablePath(for: cut.asset) == nil {
                    ContentUnavailableView {
                        Label("No picture for this part", systemImage: "play.slash")
                    } description: {
                        Text("\(cut.asset.fileName) cannot be played here yet. It keeps its place in the cut.")
                    }
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { viewerFocused = true }
    }

    // MARK: Hold to keep

    private func clipControls(_ clip: Asset) -> some View {
        VStack(spacing: 8) {
            ScrubBar(player: clipPlayer, thumbnails: model.thumbnails(for: clip), markers: [], shots: [])
                .frame(height: 40)
            HStack(spacing: 14) {
                Button { clipPlayer.togglePlay() } label: {
                    Image(systemName: clipPlayer.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 18))
                        .frame(width: 40, height: 32)
                }
                .help("Play or pause the clip")
                KeepButton(isHolding: hold != nil, label: keepLabel(clip), begin: beginHold, end: endHold)
                    .disabled(!clipPlayer.hasMedia)
                if cuts.fineTune {
                    Text(clip.timecode(atFrame: clipPlayer.currentFrame).description)
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Text(notice ?? "Hold Keep while the part you want plays, then let go. The space bar does the same.")
                .font(.callout)
                .foregroundStyle(notice == nil ? Color.secondary : Color.accentColor)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func keepLabel(_ clip: Asset) -> String {
        guard let hold else { return "Hold to Keep" }
        let seconds = clip.frameRate.seconds(forFrames: max(clipPlayer.currentFrame - hold.pressFrame, 0))
        return "Keeping  \(PlainLength.text(seconds: seconds))"
    }

    /// Keep goes down: the clip plays (from the start, if it had reached the end) and keeping begins.
    private func beginHold() {
        guard hold == nil, showsClip, clipPlayer.hasMedia else { return }
        let wasPlaying = clipPlayer.isPlaying
        if clipPlayer.currentFrame >= clipPlayer.durationFrames - 1 { clipPlayer.seek(toSeconds: 0) }
        hold = (clipPlayer.currentFrame, wasPlaying)
        notice = nil
        if !wasPlaying { clipPlayer.togglePlay() }
    }

    /// Keep comes up: what played is added to the end of the cut. A press too short to keep
    /// anything is a tap, which plays or pauses instead.
    private func endHold() {
        guard let held = hold, let clip else { return }
        hold = nil
        if let frames = HoldToKeep.range(pressFrame: held.pressFrame, releaseFrame: clipPlayer.currentFrame, in: clip) {
            if !held.wasPlaying { clipPlayer.pause() }
            if let seconds = cuts.keep(clip, frames: frames) {
                notice = "Added \(PlainLength.text(seconds: seconds)) to your cut."
            }
        } else if held.wasPlaying {
            clipPlayer.pause()
        }
    }

    // MARK: Words

    private func addChosenWords(from clip: Asset) {
        guard let frames = WordsPick.range(chosen: chosenWords, transcript: transcript, in: clip),
              let seconds = cuts.keep(clip, frames: frames) else { return }
        notice = "Added \(PlainLength.text(seconds: seconds)) to your cut."
        chosenWords = []
    }

    /// Words dragged onto the storyboard: "words:<clip>:<first frame>:<last frame>".
    private func dropWords(_ payload: String, _ index: Int?) -> Bool {
        let parts = payload.split(separator: ":").map(String.init)
        guard parts.count == 4, parts[0] == "words", let first = Int(parts[2]), let last = Int(parts[3]), first <= last,
              let asset = model.assets.first(where: { $0.id == parts[1] }),
              let seconds = cuts.keep(asset, frames: first...last, at: index) else { return false }
        notice = "Added \(PlainLength.text(seconds: seconds)) to your cut."
        chosenWords = []
        return true
    }

    // MARK: The cut

    private var cutControls: some View {
        VStack(spacing: 8) {
            SequenceScrubBar(sequence: sequence, player: cutPlayer)
                .frame(height: 22)
            HStack(spacing: 14) {
                Button { cutPlayer.togglePlay() } label: {
                    Label(cutPlayer.isPlaying ? "Pause" : "Play", systemImage: cutPlayer.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3.weight(.semibold))
                        .frame(minWidth: 150, minHeight: 36)
                }
                .buttonStyle(.borderedProminent)
                .help("Play or pause your cut (space bar)")
                if cuts.fineTune {
                    Text(sequence.recordTimecode(atFrame: cutPlayer.currentFrame).description)
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .disabled(sequence.cuts.isEmpty)
    }

    private func playAll() {
        showing = .cut
        cutPlayer.seek(toSeconds: 0)
        if !cutPlayer.isPlaying { cutPlayer.togglePlay() }
    }

    private func play(from placed: PlacedCut) {
        cuts.selectedCutID = placed.id
        showing = .cut
        cutPlayer.seek(toFrame: placed.recordStart)
        if !cutPlayer.isPlaying { cutPlayer.togglePlay() }
    }

    private func packageBar(_ progress: PackageProgress) -> some View {
        HStack(spacing: 12) {
            ProgressView(value: progress.fraction) {
                Text(progress.fileName.isEmpty ? "Exporting package" : "Exporting package: copying and checking \(progress.fileName)")
                    .lineLimit(1)
            }
            .progressViewStyle(.linear)
            Button("Stop") { cuts.cancelPackage() }
        }
        .controlSize(.small)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(.bar)
    }

    // MARK: Loading

    private func prepareClip() {
        guard let clip else {
            transcript = []
            return
        }
        transcript = (try? model.catalog.transcript(forAsset: clip.id)) ?? []
        clipPlayer.load(path: model.library?.playablePath(for: clip), frameRate: clip.frameRate,
                        durationFrames: clip.durationFrames)
        clipPlayer.applyLook(cuts.table(for: clip), key: cuts.lookKey(for: clip))
        cuts.readColourTagsIfNeeded(clip)
    }

    /// Joins the cuts from whatever can be played for each clip and shows them through their looks.
    private func prepareCut() async {
        guard !sequence.cuts.isEmpty, let library = model.library else {
            cutPlayer.load(item: nil, key: "empty", frameRate: sequence.frameRate, durationFrames: 0)
            return
        }
        let contentKey = sequence.sequence.id + sequence.cuts.map { "\($0.id):\($0.cut.inFrame)-\($0.cut.outFrame):\(library.playablePath(for: $0.asset) ?? "-")" }.joined(separator: ",")
        do {
            let playback = try await SequencePlayback.build(sequence) { library.playablePath(for: $0) }
            guard !Task.isCancelled else { return }
            cutPlayer.load(item: AVPlayerItem(asset: playback.composition), key: contentKey,
                           frameRate: sequence.frameRate, durationFrames: sequence.totalFrames)
            var looks: [(range: CMTimeRange, lut: ColorLUT)] = []
            for (segment, placed) in zip(playback.segments, sequence.cuts) where segment.hasPicture {
                if let table = cuts.table(for: placed.asset) { looks.append((segment.range, table)) }
            }
            cutPlayer.applyLooks(looks, key: contentKey + sequence.cuts.map { cuts.lookKey(for: $0.asset) }.joined())
        } catch {
            model.alert = "The cut could not be made ready to play: \(error.localizedDescription)"
        }
    }

    // MARK: Keys

    /// Space: hold to keep while a clip shows (a tap plays or pauses); play or pause the cut.
    /// Delete removes the chosen part. ⌘Z undoes, ⇧⌘Z redoes. Arrows step a frame.
    private func handle(_ press: KeyPress) -> KeyPress.Result {
        if press.key == .space {
            switch press.phase {
            case .down: showsClip ? beginHold() : cutPlayer.togglePlay()
            case .up: if showsClip { endHold() }
            default: break
            }
            return .handled
        }
        guard press.phase != .up else { return .ignored }
        let player = showsClip ? clipPlayer : cutPlayer
        switch press.key {
        case .leftArrow: player.step(frames: -1)
        case .rightArrow: player.step(frames: 1)
        case .delete, .deleteForward:
            guard press.phase == .down, let id = cuts.selectedCutID else { return .ignored }
            cuts.remove(id)
        default:
            guard press.phase == .down, press.modifiers.contains(.command), press.characters.lowercased() == "z" else { return .ignored }
            press.modifiers.contains(.shift) ? cuts.redo() : cuts.undo()
        }
        return .handled
    }
}

/// One large button that is held, not clicked. Down starts keeping; up ends it.
struct KeepButton: View {
    @Environment(\.isEnabled) private var isEnabled
    let isHolding: Bool
    let label: String
    let begin: () -> Void
    let end: () -> Void

    var body: some View {
        Label(label, systemImage: isHolding ? "record.circle.fill" : "hand.tap.fill")
            .font(.title3.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(.white)
            .frame(minWidth: 280, minHeight: 44)
            .padding(.horizontal, 16)
            .background(isHolding ? Color.red : Color.accentColor, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in if isEnabled, !isHolding { begin() } }
                .onEnded { _ in end() })
            .help("Hold this down while the part you want plays. Let go to add it to your cut.")
            .accessibilityLabel("Hold to keep")
            .accessibilityAddTraits(.isButton)
    }
}

/// A clip's dialogue as text to read and choose from.
struct WordsPanel: View {
    let asset: Asset
    let transcript: [TranscriptSegment]
    let player: PlayerController
    @Binding var chosen: Set<String>
    @Binding var lastWord: String?
    let add: () -> Void

    private var frames: ClosedRange<Int>? { WordsPick.range(chosen: chosen, transcript: transcript, in: asset) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Words").font(.headline)
                Text("Click a sentence to choose it. Shift-click to choose several.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(transcript) { line in row(line) }
                }
                .padding(.horizontal, 8)
            }
            Divider()
            HStack {
                if let frames {
                    Text("\(chosen.count) sentence\(chosen.count == 1 ? "" : "s")  ·  \(PlainLength.text(seconds: asset.frameRate.seconds(forFrames: frames.count)))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button("Add to Cut", action: add)
                    .buttonStyle(.borderedProminent)
                    .disabled(chosen.isEmpty)
                    .help("Add the chosen words to the end of your cut")
            }
            .padding(12)
        }
    }

    @ViewBuilder private func row(_ line: TranscriptSegment) -> some View {
        let isChosen = chosen.contains(line.id)
        let isSpeaking = player.currentSeconds >= line.startSeconds && player.currentSeconds < line.endSeconds
        let text = Text(line.text)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(isChosen ? Color.accentColor.opacity(0.4) : isSpeaking ? Color.white.opacity(0.1) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
            .onTapGesture { choose(line) }
        if isChosen, let frames {
            // The chosen words can be dragged onto the storyboard, to the place they should go.
            text.draggable("words:\(asset.id):\(frames.lowerBound):\(frames.upperBound)")
        } else {
            text
        }
    }

    private func choose(_ line: TranscriptSegment) {
        if NSEvent.modifierFlags.contains(.shift), let from = lastWord {
            chosen = WordsPick.run(from: from, to: line.id, in: transcript)
        } else if chosen == [line.id] {
            chosen = []
            lastWord = nil
        } else {
            chosen = [line.id]
            lastWord = line.id
            // Show where these words are in the clip.
            player.pause()
            player.seek(toSeconds: line.startSeconds)
        }
    }
}

/// The cut as a row of picture cards that wraps. Drag to reorder; drag to the bin to remove.
struct Storyboard: View {
    @Environment(CutsModel.self) private var cuts
    let sequence: ResolvedSequence
    let onPlayAll: () -> Void
    let onPlayFrom: (PlacedCut) -> Void
    /// Words dropped on the storyboard, with the position they were dropped at (nil for the end).
    let onDropWords: (String, Int?) -> Bool
    @State private var binTargeted = false
    private let columns = [GridItem(.adaptive(minimum: 220, maximum: 300), spacing: 14, alignment: .top)]

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                if sequence.cuts.isEmpty {
                    Text("Pick a clip from the library, then hold Keep while the part you want plays.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                } else {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                        ForEach(Array(sequence.cuts.enumerated()), id: \.element.id) { index, placed in
                            StoryCard(placed: placed, number: index + 1, isSelected: placed.id == cuts.selectedCutID)
                                .onTapGesture { onPlayFrom(placed) }
                                .draggable("cut:" + placed.id)
                                .dropDestination(for: String.self) { items, _ in drop(items, at: index) }
                        }
                    }
                    .padding(14)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .underPageBackgroundColor))
            .dropDestination(for: String.self) { items, _ in drop(items, at: nil) }
            if !sequence.cuts.isEmpty { bin }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("Your cut").font(.headline)
            if !sequence.cuts.isEmpty {
                Text("\(sequence.cuts.count) part\(sequence.cuts.count == 1 ? "" : "s")  ·  \(PlainLength.text(seconds: sequence.durationSeconds))")
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button { cuts.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                .help(cuts.history.undoName.map { "Undo \($0) (⌘Z)" } ?? "Nothing to undo")
                .disabled(cuts.history.undoName == nil)
            Button { cuts.redo() } label: { Label("Redo", systemImage: "arrow.uturn.forward") }
                .labelStyle(.iconOnly)
                .help(cuts.history.redoName.map { "Redo \($0) (⇧⌘Z)" } ?? "Nothing to redo")
                .disabled(cuts.history.redoName == nil)
            Button(action: onPlayAll) { Label("Play", systemImage: "play.fill") }
                .buttonStyle(.borderedProminent)
                .help("Play your whole cut from the start")
                .disabled(sequence.cuts.isEmpty)
            Toggle("Fine tune", isOn: Binding(get: { cuts.fineTune }, set: { cuts.fineTune = $0 }))
                .toggleStyle(.switch)
                .help("Show timecode and frame-by-frame controls")
        }
        .controlSize(.small)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var bin: some View {
        Label("Drag a part here to remove it", systemImage: "trash")
            .font(.callout)
            .foregroundStyle(binTargeted ? Color.red : Color.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(binTargeted ? Color.red.opacity(0.18) : Color.white.opacity(0.04))
            .dropDestination(for: String.self) { items, _ in
                guard let id = cutID(in: items) else { return false }
                cuts.remove(id)
                return true
            } isTargeted: { binTargeted = $0 }
    }

    private func cutID(in items: [String]) -> String? {
        guard let item = items.first, item.hasPrefix("cut:") else { return nil }
        let id = String(item.dropFirst(4))
        return sequence.cuts.contains { $0.id == id } ? id : nil
    }

    /// A card dropped on a card moves there; words dropped anywhere become a new part there.
    private func drop(_ items: [String], at index: Int?) -> Bool {
        if let id = cutID(in: items) {
            guard let index, sequence.cuts[index].id != id else { return false }
            cuts.move(id, to: index)
            return true
        }
        guard let item = items.first, item.hasPrefix("words:") else { return false }
        return onDropWords(item, index)
    }
}

/// One part of the cut: a frame, the clip's name and a plain length. Its left and right edges
/// drag to make it shorter or longer, and the picture shows where the edge now is.
struct StoryCard: View {
    @Environment(AppModel.self) private var model
    @Environment(CutsModel.self) private var cuts
    let placed: PlacedCut
    let number: Int
    let isSelected: Bool
    /// While an edge is dragged: the range it would give, and the frame at that edge.
    @State private var dragged: ClosedRange<Int>?
    @State private var edgeImage: NSImage?
    @State private var imageTask: Task<Void, Never>?
    @State private var generator: AVAssetImageGenerator?
    /// How far an edge is dragged for one second of the clip.
    private static let pointsPerSecond = 40.0

    private var frames: ClosedRange<Int> { dragged ?? placed.cut.inFrame...placed.cut.outFrame }

    var body: some View {
        let asset = placed.asset
        VStack(alignment: .leading, spacing: 5) {
            ZStack(alignment: .topLeading) {
                Rectangle().fill(Color.black)
                if let image = edgeImage ?? thumbnail {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                } else {
                    Image(systemName: asset.decodePath.canRender ? "film" : "camera.aperture")
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                HStack(spacing: 4) {
                    Badge(text: "\(number)")
                    if !asset.decodePath.canRender { Badge(text: "RAW", tint: .orange) }
                    if model.offline.contains(asset.id) { Badge(text: "OFFLINE", tint: .red) }
                }
                .padding(7)
                HStack(spacing: 0) {
                    edgeHandle(.start)
                    Spacer(minLength: 0)
                    edgeHandle(.end)
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(isSelected || dragged != nil ? Color.accentColor : Color.white.opacity(0.08),
                                  lineWidth: isSelected || dragged != nil ? 2.5 : 1)
            }
            Text(asset.fileName)
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
            Text(PlainLength.text(seconds: asset.frameRate.seconds(forFrames: frames.count)))
                .font(.callout)
                .foregroundStyle(dragged == nil ? Color.secondary : Color.accentColor)
            if cuts.fineTune {
                Text("\(asset.timecode(atFrame: frames.lowerBound).description) – \(asset.timecode(atFrame: frames.upperBound).description)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if isSelected {
                HStack(spacing: 6) {
                    Button("Shorter") { nudge(-1) }
                        .help("Take a second off the end of this part")
                    Button("Longer") { nudge(1) }
                        .help("Add a second to the end of this part")
                    Spacer(minLength: 0)
                    Button("Remove", role: .destructive) { cuts.remove(placed.id) }
                        .help("Take this part out of your cut. Undo brings it back.")
                }
                .controlSize(.small)
            }
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button("Move Earlier") { cuts.move(placed.id, by: -1) }
            Button("Move Later") { cuts.move(placed.id, by: 1) }
            Divider()
            Button("Show the Whole Clip") {
                model.selectedID = placed.asset.id
                model.pendingSeekSeconds = placed.asset.frameRate.seconds(forFrames: placed.cut.inFrame)
            }
            Menu("Look") { LookMenu(asset: placed.asset) }
            Divider()
            Button("Remove", role: .destructive) { cuts.remove(placed.id) }
        }
        .onDisappear { imageTask?.cancel() }
    }

    /// A grip down one side of the picture. Dragging it moves that end of the part.
    private func edgeHandle(_ edge: EdgeTrim.Edge) -> some View {
        ZStack {
            LinearGradient(colors: [.black.opacity(0.55), .clear],
                           startPoint: edge == .start ? .leading : .trailing, endPoint: edge == .start ? .trailing : .leading)
            Capsule()
                .fill(Color.white.opacity(0.9))
                .frame(width: 4, height: 34)
                .shadow(color: .black, radius: 2)
        }
        .frame(width: 22)
        .contentShape(Rectangle())
        .highPriorityGesture(DragGesture(minimumDistance: 2)
            .onChanged { value in
                let range = EdgeTrim.range(of: placed.cut, in: placed.asset, moving: edge,
                                           bySeconds: value.translation.width / Self.pointsPerSecond)
                guard range != dragged else { return }
                dragged = range
                showFrame(edge == .start ? range.lowerBound : range.upperBound)
            }
            .onEnded { _ in
                if let range = dragged, range != placed.cut.inFrame...placed.cut.outFrame {
                    cuts.setRange(placed.id, to: range, name: range.count < placed.cut.durationFrames ? "Shorter" : "Longer")
                }
                dragged = nil
                edgeImage = nil
                generator = nil
                imageTask?.cancel()
            })
        .help(edge == .start ? "Drag to change where this part starts" : "Drag to change where this part ends")
    }

    private func nudge(_ seconds: Double) {
        let range = EdgeTrim.range(of: placed.cut, in: placed.asset, moving: .end, bySeconds: seconds)
        cuts.setRange(placed.id, to: range, name: seconds < 0 ? "Shorter" : "Longer")
    }

    /// Fetches the picture at a frame of the clip, so the card follows the edge being dragged.
    private func showFrame(_ frame: Int) {
        guard let path = model.library?.playablePath(for: placed.asset) else { return }
        if generator == nil {
            let made = AVAssetImageGenerator(asset: AVURLAsset(url: URL(fileURLWithPath: path)))
            made.appliesPreferredTrackTransform = true
            made.maximumSize = CGSize(width: 640, height: 360)
            // Near enough is fine while dragging, and much quicker than the exact frame.
            made.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 10)
            made.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 10)
            generator = made
        }
        guard let generator else { return }
        let time = CMTime(seconds: placed.asset.frameRate.seconds(forFrames: frame), preferredTimescale: 60_000)
        imageTask?.cancel()
        imageTask = Task {
            guard let image = try? await generator.image(at: time).image, !Task.isCancelled, dragged != nil else { return }
            edgeImage = NSImage(cgImage: image, size: .zero)
        }
    }

    /// The contact-sheet frame nearest where the part starts.
    private var thumbnail: NSImage? {
        let thumbnails = model.thumbnails(for: placed.asset)
        guard !thumbnails.isEmpty else { return nil }
        let fraction = Double(placed.cut.inFrame) / Double(max(placed.asset.durationFrames, 1))
        return ThumbnailCache.image(atPath: thumbnails[min(Int(fraction * Double(thumbnails.count)), thumbnails.count - 1)])
    }
}

/// The whole cut as one bar: a block per part, the playhead, drag to move through it.
struct SequenceScrubBar: View {
    @Environment(CutsModel.self) private var cuts
    let sequence: ResolvedSequence
    let player: PlayerController

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let total = CGFloat(max(sequence.totalFrames, 1))
            ZStack(alignment: .leading) {
                Color.white.opacity(0.06)
                ForEach(sequence.cuts) { placed in
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(placed.id == cuts.selectedCutID ? Color.accentColor.opacity(0.6) : Color.white.opacity(0.22))
                        .frame(width: max(CGFloat(placed.recordFrames) / total * width - 1, 1))
                        .offset(x: CGFloat(placed.recordStart) / total * width)
                }
                Rectangle()
                    .fill(Color.white)
                    .frame(width: 2)
                    .shadow(color: .black, radius: 2)
                    .offset(x: CGFloat(player.currentFrame) / total * width - 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                player.pause()
                player.seek(toFrame: Int(min(max(value.location.x / width, 0), 1) * (total - 1)))
            })
        }
    }
}

/// Fine tune only: nudge either end of the chosen part a frame at a time, or bring it to the playhead.
struct CutTrimBar: View {
    @Environment(CutsModel.self) private var cuts
    let sequence: ResolvedSequence
    let placed: PlacedCut
    let player: PlayerController

    /// The source frame under the playhead, when the playhead is inside this cut.
    private var playheadFrame: Int? {
        let frame = player.currentFrame
        guard frame >= placed.recordStart, frame < placed.recordEnd else { return nil }
        let into = Double(frame - placed.recordStart) * placed.asset.frameRate.fps / sequence.frameRate.fps
        return placed.cut.inFrame + min(Int(into.rounded()), placed.cut.durationFrames - 1)
    }

    var body: some View {
        let asset = placed.asset, cut = placed.cut
        HStack(spacing: 18) {
            end("In", timecode: placed.sourceIn, canGoBack: cut.inFrame > 0, canGoForward: cut.inFrame < cut.outFrame,
                nudge: { cuts.trim(cut.id, inFrame: cut.inFrame + $0) },
                toPlayhead: playheadFrame.map { frame in { cuts.trim(cut.id, inFrame: frame) } })
            end("Out", timecode: asset.timecode(atFrame: cut.outFrame), canGoBack: cut.outFrame > cut.inFrame,
                canGoForward: asset.durationFrames == 0 || cut.outFrame < asset.durationFrames - 1,
                nudge: { cuts.trim(cut.id, outFrame: cut.outFrame + $0) },
                toPlayhead: playheadFrame.map { frame in { cuts.trim(cut.id, outFrame: frame) } })
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 1) {
                Text(Timecode(frames: cut.durationFrames, rate: asset.frameRate).description)
                    .font(.callout.monospacedDigit().weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                Text("Length").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .controlSize(.small)
    }

    private func end(_ title: String, timecode: Timecode, canGoBack: Bool, canGoForward: Bool,
                     nudge: @escaping (Int) -> Void, toPlayhead: (() -> Void)?) -> some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(timecode.description).font(.callout.monospacedDigit())
                Text(title).font(.caption2).foregroundStyle(.secondary)
            }
            .fixedSize()
            Button { nudge(-1) } label: { Image(systemName: "minus") }
                .help("\(title) point one frame earlier")
                .disabled(!canGoBack)
            Button { nudge(1) } label: { Image(systemName: "plus") }
                .help("\(title) point one frame later")
                .disabled(!canGoForward)
            Button("To Playhead") { toPlayhead?() }
                .help("Move the \(title.lowercased()) point to the playhead")
                .disabled(toPlayhead == nil)
                .fixedSize()
        }
    }
}

/// Chooses what a clip is shown through. Used in the clip player's toolbar and on a part of a cut.
struct LookMenu: View {
    @Environment(CutsModel.self) private var cuts
    let asset: Asset

    var body: some View {
        let chosen = cuts.chosenLook(for: asset)
        let detected = LookConversion.detect(colorSpace: asset.colorSpace)
        Toggle("Automatic (\(detected?.displayName ?? "no log format found in this clip"))",
               isOn: Binding(get: { chosen == nil }, set: { _ in cuts.setLook(nil, for: asset) }))
        Toggle("No look", isOn: binding(ViewingLook.none, chosen))
        Divider()
        ForEach(LookConversion.allCases, id: \.self) { conversion in
            Toggle(conversion.displayName, isOn: binding(.conversion(conversion), chosen))
        }
        Divider()
        ForEach(cuts.lutsInUse, id: \.self) { path in
            Toggle(ViewingLook.lut(path: path).displayName, isOn: binding(.lut(path: path), chosen))
        }
        Button("Load .cube LUT…") { cuts.chooseLUT(for: asset) }
    }

    private func binding(_ look: ViewingLook, _ chosen: ViewingLook?) -> Binding<Bool> {
        Binding(get: { chosen == look }, set: { _ in cuts.setLook(look, for: asset) })
    }
}
