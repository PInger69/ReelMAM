import AppKit
import StadaMAMCore
import SwiftUI

/// Where a person shapes what the picture A.I. says: how sure it must be, which labels to drop,
/// and which to reword in the department's own language.
struct LabelRulesView: View {
    @Environment(AppModel.self) private var model
    @State private var counts: [(label: String, count: Int)] = []
    @State private var newMatch = ""
    @State private var newReplacement = ""
    @State private var search = ""

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 14) {
            Text("The picture A.I. names what it sees in each clip. Hide the labels you never search for, and reword the rest the way your crew says them. Changes apply to every clip already analysed and to every clip analysed from now on. Tags you add or rename by hand are never overwritten.")
                .font(.callout).foregroundStyle(.secondary)

            HStack {
                Text("Keep a label when the A.I. is at least")
                Slider(value: $model.labelThreshold, in: 0.2...0.9, step: 0.05).frame(width: 160)
                Text("\(Int(model.labelThreshold * 100))% sure").monospacedDigit().frame(width: 70, alignment: .leading)
            }
            Text("Applies the next time a clip is analysed. Higher means fewer, safer labels.")
                .font(.caption).foregroundStyle(.secondary)

            Divider()
            Text("Rules").font(.headline)
            HStack {
                TextField("When the A.I. says…", text: $newMatch).textFieldStyle(.roundedBorder)
                Image(systemName: "arrow.right")
                TextField("…say this (empty hides it)", text: $newReplacement).textFieldStyle(.roundedBorder)
                Button("Add Rule") {
                    model.addRule(LabelRule(match: newMatch, action: newReplacement.isEmpty ? .hide : .rename,
                                            replacement: newReplacement))
                    newMatch = ""; newReplacement = ""; counts = model.labelCounts()
                }
                .disabled(newMatch.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            List {
                ForEach(model.labelRules) { rule in
                    HStack {
                        Text(rule.match).frame(width: 160, alignment: .leading)
                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                        Text(rule.action == .hide ? "hidden" : rule.replacement)
                            .foregroundStyle(rule.action == .hide ? .secondary : .primary)
                        Spacer()
                        Button { model.deleteRule(rule) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                            .help("Delete this rule. Labels already changed stay changed; re-analyse to bring them back.")
                    }
                }
            }
            .frame(minHeight: 150)

            Divider()
            HStack {
                Text("Labels in your footage").font(.headline)
                Spacer()
                TextField("Filter", text: $search).textFieldStyle(.roundedBorder).frame(width: 160)
                Button("Refresh") { counts = model.labelCounts() }
            }
            List {
                ForEach(counts.filter { search.isEmpty || $0.label.localizedCaseInsensitiveContains(search) }, id: \.label) { item in
                    HStack {
                        Text(item.label)
                        Text("\(item.count)").foregroundStyle(.secondary).monospacedDigit()
                        Spacer()
                        Button("Reword…") { newMatch = item.label; newReplacement = "" }.controlSize(.small)
                        Button("Hide") { model.hideEverywhere(item.label); counts = model.labelCounts() }.controlSize(.small)
                    }
                }
            }
            .frame(minHeight: 150)
        }
        .padding(20)
        .onAppear { counts = model.labelCounts() }
    }
}

/// Dialogue language, names to listen for, and where the big files go.
struct DialogueAndStorageView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Dialogue") {
                TextField("Spoken language", text: $model.dialogueLanguage, prompt: Text("en-US — empty uses this Mac's language"))
                Text("Names of characters, places and crew help the dialogue log get unusual names right — one per line. Everyone you name in the Cast tab is included automatically.")
                    .font(.callout).foregroundStyle(.secondary)
                TextEditor(text: $model.dialogueVocabulary)
                    .font(.body)
                    .frame(height: 120)
                    .border(Color.secondary.opacity(0.4))
            }
            Section("Proxy storage") {
                HStack {
                    Text(model.proxyFolder.isEmpty ? "Default (Movies folder)" : model.proxyFolder)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Choose…") {
                        let panel = NSOpenPanel()
                        panel.canChooseFiles = false
                        panel.canChooseDirectories = true
                        panel.canCreateDirectories = true
                        panel.prompt = "Use for Proxies"
                        panel.message = "Choose a folder on a large volume. A feature's proxies can run to tens of terabytes."
                        if panel.runModal() == .OK, let url = panel.url { model.proxyFolder = url.path }
                    }
                    if !model.proxyFolder.isEmpty { Button("Default") { model.proxyFolder = "" } }
                }
                Text("New proxies go here. Proxies already made stay where they are and keep working.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(20)
    }
}
