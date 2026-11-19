import StadaMAMCore
import SwiftUI

enum InspectorTab: String, CaseIterable, Identifiable {
    case info = "Info"
    case markers = "Markers"
    case transcript = "Transcript"
    case scenes = "Scenes"
    case people = "People"

    var id: String { rawValue }
}

struct InspectorView: View {
    @Environment(AppModel.self) private var model
    let asset: Asset
    let data: ClipData
    let player: PlayerController
    @State private var tab = InspectorTab.info

    var body: some View {
        VStack(spacing: 0) {
            Picker("Section", selection: $tab) {
                ForEach(InspectorTab.allCases) { tab in
                    Text(label(for: tab)).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(10)
            Divider()
            ScrollView {
                Group {
                    switch tab {
                    case .info: InfoPane(asset: asset, proxies: data.proxies)
                    case .markers: MarkersPane(asset: asset, markers: data.markers, player: player)
                    case .transcript: TranscriptPane(asset: asset, segments: data.transcript, player: player)
                    case .scenes: ScenesPane(asset: asset, tags: data.tags, player: player)
                    case .people: PeoplePane(asset: asset, faces: data.faces, player: player)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func label(for tab: InspectorTab) -> String {
        let count: Int
        switch tab {
        case .info: return tab.rawValue
        case .markers: count = data.markers.count
        case .transcript: count = data.transcript.count
        case .scenes: count = data.tags.count
        case .people: count = Set(data.faces.compactMap(\.personID)).count
        }
        return count > 0 ? "\(tab.rawValue) (\(count))" : tab.rawValue
    }
}

private struct EmptyPane: View {
    var title: String
    var symbol: String
    var message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            Text(message)
        } actions: {
            if let actionTitle, let action { Button(actionTitle, action: action) }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct InfoPane: View {
    @Environment(AppModel.self) private var model
    let asset: Asset
    let proxies: [ProxyRecord]
    @State private var notes = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                row("Format", [asset.formatName.isEmpty ? asset.videoCodec?.uppercased() : asset.formatName,
                               asset.container?.uppercased()].compactMap { $0 }.joined(separator: " in "))
                row("Picture", picture)
                row("Standard", standard)
                row("Frame rate", asset.height > 0 ? String(format: "%.3f fps", asset.frameRate.fps) : "—")
                row("Decoding", decoding)
                row("Start timecode", asset.startTimecode.description)
                row("Duration", Timecode(frames: asset.durationFrames, rate: asset.frameRate).description)
                row("Reel", asset.reelName ?? "—")
                row("Audio", asset.audioChannels > 0 ? "\(asset.audioChannels) channel\(asset.audioChannels == 1 ? "" : "s")" : "None")
                row("Size", ByteCountFormatter.string(fromByteCount: asset.fileSize, countStyle: .file))
                row("Volume", asset.volumeName ?? "Internal")
            }

            HStack(spacing: 2) {
                ForEach(1...5, id: \.self) { star in
                    Button {
                        var updated = asset
                        updated.rating = asset.rating == star ? 0 : star
                        model.update(updated)
                    } label: {
                        Image(systemName: star <= asset.rating ? "star.fill" : "star")
                            .foregroundStyle(star <= asset.rating ? Color.yellow : Color.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Source").font(.headline)
                pathRow(asset.sourcePath, symbol: "internaldrive")
                Text("Proxies").font(.headline).padding(.top, 4)
                if proxies.isEmpty {
                    Text("No proxy yet.").foregroundStyle(.secondary)
                }
                ForEach(proxies) { proxy in
                    pathRow(proxy.path, symbol: proxy.status == .ready ? "checkmark.seal.fill" : "exclamationmark.triangle",
                            caption: "\(proxy.preset.displayName)  ·  \(proxy.status.rawValue)")
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Notes").font(.headline)
                TextField("Add notes — they are searchable", text: $notes, axis: .vertical)
                    .lineLimit(2...6)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(saveNotes)
                if notes != asset.notes {
                    Button("Save Notes", action: saveNotes).controlSize(.small)
                }
            }
        }
        .onAppear { notes = asset.notes }
    }

    private var picture: String {
        guard asset.width > 0 else { return "Not readable without the camera maker's decoder" }
        var text = "\(asset.width) × \(asset.height)  ·  \(asset.resolutionClass)"
        if asset.pixelAspectNum != asset.pixelAspectDen {
            text += "  ·  pixel aspect \(asset.pixelAspectNum):\(asset.pixelAspectDen) (displays \(asset.displayWidth) wide)"
        }
        return text
    }

    private var standard: String {
        guard asset.height > 0 else { return "—" }
        let standards = asset.broadcastStandards.map(\.rawValue)
        return asset.pictureFormatName + (standards.isEmpty ? "" : "  ·  " + standards.joined(separator: ", "))
    }

    private var decoding: String {
        switch asset.decodePath {
        case .avFoundation: return "Native"
        case .ffmpeg: return "FFmpeg (plays through its proxy)"
        case .blackmagicRAW: return "Needs the Blackmagic RAW SDK"
        case .unsupported: return "Needs the camera maker's SDK"
        }
    }

    private func saveNotes() {
        var updated = asset
        updated.notes = notes
        model.update(updated)
    }

    private func row(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(value.isEmpty ? "—" : value).textSelection(.enabled)
        }
    }

    private func pathRow(_ path: String, symbol: String, caption: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(path).font(.callout).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                if let caption { Text(caption).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            Button("Reveal") { model.revealInFinder(path) }.controlSize(.small)
        }
    }
}

private struct MarkersPane: View {
    @Environment(AppModel.self) private var model
    let asset: Asset
    let markers: [Marker]
    let player: PlayerController

    var body: some View {
        if markers.isEmpty {
            EmptyPane(title: "No markers", symbol: "bookmark",
                      message: "Press M to drop a marker, or mark in (I) and out (O) and save a subclip.")
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(markers) { marker in
                    MarkerRow(asset: asset, marker: marker, player: player)
                }
            }
        }
    }
}

private struct MarkerRow: View {
    @Environment(AppModel.self) private var model
    let asset: Asset
    let marker: Marker
    let player: PlayerController
    @State private var name = ""

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: marker.isSubclip ? "scissors" : "bookmark.fill")
                .foregroundStyle(marker.isSubclip ? Color.orange : Color.cyan)
            Button {
                player.seek(toFrame: marker.inFrame)
                if let out = marker.outFrame {
                    player.inFrame = marker.inFrame
                    player.outFrame = out
                }
            } label: {
                Text(range).font(.callout.monospacedDigit())
            }
            .buttonStyle(.link)
            TextField("Name", text: $name)
                .textFieldStyle(.plain)
                .onSubmit {
                    var updated = marker
                    updated.name = name
                    model.update(updated)
                }
            Button(role: .destructive) { model.delete(marker) } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
        }
        .padding(.vertical, 3)
        .onAppear { name = marker.name }
    }

    private var range: String {
        let start = asset.timecode(atFrame: marker.inFrame).description
        guard let out = marker.outFrame else { return start }
        return "\(start) → \(asset.timecode(atFrame: out).description)"
    }
}

private struct TranscriptPane: View {
    @Environment(AppModel.self) private var model
    let asset: Asset
    let segments: [TranscriptSegment]
    let player: PlayerController

    var body: some View {
        if segments.isEmpty {
            EmptyPane(title: "No transcript", symbol: "captions.bubble",
                      message: "Analyse the clip to transcribe its speech, search it and export captions.",
                      actionTitle: "Analyse with A.I.") { model.analyze(asset) }
        } else {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Button("Export SRT…") { model.exportCaptions(for: asset, webVTT: false) }
                    Button("Export WebVTT…") { model.exportCaptions(for: asset, webVTT: true) }
                }
                .controlSize(.small)
                .padding(.bottom, 8)
                ForEach(segments) { segment in
                    let isCurrent = player.currentSeconds >= segment.startSeconds && player.currentSeconds < segment.endSeconds
                    Button { player.seek(toSeconds: segment.startSeconds) } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(asset.timecode(atFrame: asset.frameRate.frames(forSeconds: segment.startSeconds)).description)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Text(segment.text)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .multilineTextAlignment(.leading)
                        }
                        .padding(.vertical, 4)
                        .padding(.horizontal, 6)
                        .background(isCurrent ? Color.accentColor.opacity(0.25) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 5))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

private struct ScenesPane: View {
    @Environment(AppModel.self) private var model
    let asset: Asset
    let tags: [SceneTag]
    let player: PlayerController

    var body: some View {
        if tags.isEmpty {
            EmptyPane(title: "Not analysed", symbol: "sparkles",
                      message: "Analyse the clip to detect shots, recognise scenes and objects, and read on-screen text.",
                      actionTitle: "Analyse with A.I.") { model.analyze(asset) }
        } else {
            VStack(alignment: .leading, spacing: 14) {
                section("Shots", tags.filter { $0.kind == .shot }, tint: .gray)
                section("Scenes and objects", tags.filter { $0.kind == .label }, tint: .purple)
                section("On-screen text", tags.filter { $0.kind == .text }, tint: .teal)
            }
        }
    }

    @ViewBuilder private func section(_ title: String, _ items: [SceneTag], tint: Color) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 6, alignment: .leading)],
                          alignment: .leading, spacing: 6) {
                    ForEach(items) { tag in
                        Button { player.seek(toSeconds: tag.startSeconds) } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(tag.label).lineLimit(1)
                                Text(asset.timecode(atFrame: asset.frameRate.frames(forSeconds: tag.startSeconds)).description)
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(tint.opacity(0.22), in: RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

private struct PeoplePane: View {
    @Environment(AppModel.self) private var model
    let asset: Asset
    let faces: [FaceSighting]
    let player: PlayerController

    var body: some View {
        let grouped = Dictionary(grouping: faces.filter { $0.personID != nil }, by: { $0.personID! })
        let people = model.people.filter { grouped[$0.id] != nil }
        if people.isEmpty {
            EmptyPane(title: "No people found", symbol: "person.crop.rectangle.stack",
                      message: "Analyse the clip to find faces. Name a person once and every clip they appear in becomes searchable.",
                      actionTitle: "Analyse with A.I.") { model.analyze(asset) }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(people) { person in
                    PersonRow(asset: asset, person: person, sightings: grouped[person.id] ?? [], player: player)
                }
            }
        }
    }
}

private struct PersonRow: View {
    @Environment(AppModel.self) private var model
    let asset: Asset
    let person: Person
    let sightings: [FaceSighting]
    let player: PlayerController
    @State private var name = ""

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "person.crop.circle.fill").font(.title2).foregroundStyle(.secondary)
            TextField("Name this person", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 240)
                .onSubmit { model.rename(person, to: name) }
            Text("\(sightings.count) sighting\(sightings.count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if let first = sightings.first {
                Button("Go to First") { player.seek(toSeconds: first.timeSeconds) }.controlSize(.small)
            }
        }
        .onAppear { name = person.name ?? "" }
    }
}
