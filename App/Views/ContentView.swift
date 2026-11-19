import AppKit
import StadaMAMCore
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 280)
        } content: {
            LibraryGridView()
                .navigationSplitViewColumnWidth(min: 300, ideal: 480)
        } detail: {
            if let asset = model.selectedAsset {
                ClipDetailView(asset: asset)
                    .id(asset.id)
            } else {
                ContentUnavailableView("Select a clip", systemImage: "film.stack",
                                       description: Text("Choose a clip to play, mark and inspect it."))
            }
        }
        .searchable(text: $model.searchText, prompt: "Search names, speech, scenes, text and people")
        .toolbar {
            ToolbarItemGroup {
                Button { model.presentImportPanel() } label: {
                    Label("Import", systemImage: "square.and.arrow.down")
                }
                .help("Import clips or folders")
                Menu {
                    ForEach(ProxyPreset.allCases, id: \.self) { preset in
                        Button(preset.displayName) { model.makeMissingProxies(preset: preset) }
                    }
                } label: {
                    Label("Make Proxies", systemImage: "bolt.fill")
                }
                .help("Render a proxy for every clip that does not have one")
                Menu {
                    SendToEditorMenu()
                } label: {
                    Label("Send to Editor", systemImage: "paperplane.fill")
                }
                .help("Hand the clips shown, with markers and subclips, to Final Cut Pro, DaVinci Resolve or Premiere Pro")
                Button { model.presentRecallPanel() } label: {
                    Label("Find Source", systemImage: "arrow.triangle.2.circlepath")
                }
                .help("Find the high-res source for a proxy or an exported timeline")
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.importMedia(at: urls.map(\.path))
            return true
        }
        .alert("StadaXR A.I. MAM", isPresented: Binding(get: { model.alert != nil },
                                                        set: { if !$0 { model.alert = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.alert ?? "")
        }
        .sheet(item: $model.recall) { report in
            RecallView(report: report)
        }
    }
}

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List(selection: Binding<LibraryFilter?>(get: { model.filter }, set: { model.select(filter: $0 ?? .all) })) {
            Section("Library") {
                Label("All Clips", systemImage: "film.stack").tag(LibraryFilter.all)
                Label("Needs Proxy", systemImage: "hourglass").tag(LibraryFilter.needsProxy)
                Label("Has Proxy", systemImage: "checkmark.seal").tag(LibraryFilter.hasProxy)
                Label("Transcribed", systemImage: "captions.bubble").tag(LibraryFilter.transcribed)
                if !model.offline.isEmpty {
                    Label("Offline (\(model.offline.count))", systemImage: "exclamationmark.triangle")
                        .tag(LibraryFilter.offline)
                        .contextMenu {
                            Button("Locate Missing Originals…") { model.presentLocateMissingPanel() }
                        }
                }
            }
            if !model.people.isEmpty {
                Section("People") {
                    ForEach(Array(model.people.enumerated()), id: \.element.id) { index, person in
                        Label(person.name ?? "Unnamed person \(index + 1)",
                              systemImage: person.name == nil ? "person.crop.circle.badge.questionmark" : "person.crop.circle")
                            .tag(LibraryFilter.person(person.id))
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }
}

struct LibraryGridView: View {
    @Environment(AppModel.self) private var model
    private let columns = [GridItem(.adaptive(minimum: 200, maximum: 320), spacing: 16)]

    var body: some View {
        let assets = model.visibleAssets
        Group {
            if model.assets.isEmpty {
                ContentUnavailableView {
                    Label("No media yet", systemImage: "square.and.arrow.down.on.square")
                } description: {
                    Text("Drop clips or folders here, or import them. Files stay where they are.")
                } actions: {
                    Button("Import Media…") { model.presentImportPanel() }
                }
            } else if assets.isEmpty {
                ContentUnavailableView.search(text: model.searchText)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 18) {
                        ForEach(assets) { asset in
                            AssetCard(asset: asset)
                                .onTapGesture { select(asset) }
                                // Drag a clip straight into an editing app's bin or timeline.
                                .draggable(URL(fileURLWithPath: asset.sourcePath))
                                .contextMenu { AssetActions(asset: asset) }
                        }
                    }
                    .padding(16)
                }
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor))
        .navigationTitle("Library")
        .navigationSubtitle("\(assets.count) clip\(assets.count == 1 ? "" : "s")")
    }

    private func select(_ asset: Asset) {
        model.selectedID = asset.id
        // Jump straight to the moment that matched the search.
        model.pendingSeekSeconds = model.bestHit(for: asset.id)?.timeSeconds
    }
}

/// The actions available on a clip, shared by the grid's context menu and the detail toolbar.
struct AssetActions: View {
    @Environment(AppModel.self) private var model
    let asset: Asset

    var body: some View {
        Menu("Generate Proxy") {
            ForEach(ProxyPreset.allCases, id: \.self) { preset in
                Button(preset.displayName) { model.makeProxy(for: asset, preset: preset) }
            }
        }
        Button("Analyse with A.I.") { model.analyze(asset) }
        Divider()
        Button("Reveal Source in Finder") { model.revealInFinder(asset.sourcePath) }
        if model.offline.contains(asset.id) {
            Button("Locate Missing Originals…") { model.presentLocateMissingPanel() }
        }
    }
}

struct AssetCard: View {
    @Environment(AppModel.self) private var model
    let asset: Asset
    @State private var hoverFraction: CGFloat?

    var body: some View {
        let thumbnails = model.thumbnailPaths[asset.id] ?? []
        let isSelected = model.selectedID == asset.id
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { proxy in
                ZStack {
                    Rectangle().fill(Color.black)
                    if let image = currentImage(thumbnails) {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: proxy.size.width, height: proxy.size.height)
                            .clipped()
                    } else {
                        Image(systemName: asset.decodePath.canRender ? "film" : "camera.aperture")
                            .font(.system(size: 30, weight: .light))
                            .foregroundStyle(.tertiary)
                    }
                    LinearGradient(colors: [.black.opacity(0.55), .clear, .black.opacity(0.65)],
                                   startPoint: .top, endPoint: .bottom)
                    if let fraction = hoverFraction, thumbnails.count > 1 {
                        Rectangle()
                            .fill(Color.accentColor)
                            .frame(width: 2)
                            .position(x: fraction * proxy.size.width, y: proxy.size.height / 2)
                    }
                    overlayBadges
                }
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point): hoverFraction = min(max(point.x / max(proxy.size.width, 1), 0), 1)
                    case .ended: hoverFraction = nil
                    }
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor : Color.white.opacity(0.08),
                                  lineWidth: isSelected ? 2.5 : 1)
            }
            .shadow(color: .black.opacity(0.35), radius: isSelected ? 10 : 4, y: 3)

            Text(asset.fileName)
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
            if let hit = model.bestHit(for: asset.id), hit.kind != .asset {
                Label(hit.snippet, systemImage: icon(for: hit.kind))
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
                    .lineLimit(2)
            } else {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .contentShape(Rectangle())
    }

    private var subtitle: String {
        var parts: [String] = []
        if asset.width > 0 {
            parts.append(asset.resolutionClass)
            parts.append(asset.pictureFormatName)
        } else if !asset.formatName.isEmpty {
            parts.append(asset.formatName)
        }
        if let volume = asset.volumeName { parts.append(volume) }
        return parts.isEmpty ? "Catalogued" : parts.joined(separator: "  ·  ")
    }

    @ViewBuilder private var overlayBadges: some View {
        VStack {
            HStack(spacing: 4) {
                Badge(text: (asset.videoCodec ?? asset.container ?? "clip").uppercased())
                if !asset.decodePath.canRender { Badge(text: "RAW", tint: .orange) }
                if model.offline.contains(asset.id) { Badge(text: "OFFLINE", tint: .red) }
                if model.hasProxy(asset) { Badge(text: "PROXY", tint: .green) }
                Spacer()
            }
            Spacer()
            if let activity = model.activity[asset.id] {
                VStack(alignment: .leading, spacing: 3) {
                    Text(activity.title).font(.caption2.weight(.semibold))
                    if let progress = activity.progress {
                        ProgressView(value: progress)
                    } else {
                        ProgressView().progressViewStyle(.linear)
                    }
                }
                .tint(.white)
            } else {
                HStack {
                    Spacer()
                    if asset.durationFrames > 0 {
                        Text(Timecode(frames: asset.durationFrames, rate: asset.frameRate).description)
                            .font(.caption2.monospacedDigit().weight(.semibold))
                    }
                }
            }
        }
        .padding(8)
        .foregroundStyle(.white)
    }

    private func currentImage(_ thumbnails: [String]) -> NSImage? {
        guard !thumbnails.isEmpty else { return nil }
        // Resting state shows a frame a third of the way in; hovering scrubs through the clip.
        let fraction = hoverFraction ?? 0.34
        let index = min(Int(fraction * CGFloat(thumbnails.count)), thumbnails.count - 1)
        return ThumbnailCache.image(atPath: thumbnails[index])
    }

    private func icon(for kind: SearchHit.Kind) -> String {
        switch kind {
        case .asset: return "film"
        case .transcript: return "captions.bubble"
        case .tag: return "sparkles"
        case .marker: return "bookmark"
        case .person: return "person.crop.circle"
        }
    }
}

struct Badge: View {
    var text: String
    var tint: Color = .white

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(.black.opacity(0.55), in: Capsule())
            .overlay(Capsule().strokeBorder(tint.opacity(0.5), lineWidth: 0.5))
            .foregroundStyle(tint)
    }
}

enum ThumbnailCache {
    private static let cache = NSCache<NSString, NSImage>()

    static func image(atPath path: String) -> NSImage? {
        if let cached = cache.object(forKey: path as NSString) { return cached }
        guard let image = NSImage(contentsOfFile: path) else { return nil }
        cache.setObject(image, forKey: path as NSString)
        return image
    }
}

/// One entry per editing app, each offering the camera originals or the proxies alone.
struct SendToEditorMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ForEach(EditorTarget.allCases, id: \.self) { target in
            Menu(target.displayName) {
                Button("Camera originals" + (target == .finalCutPro ? " with proxies attached" : "")) {
                    model.sendToEditor(target, media: .sources)
                }
                Button("Proxies only (editor has no originals)") {
                    model.sendToEditor(target, media: .proxies)
                }
            }
        }
    }
}
