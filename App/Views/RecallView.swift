import StradaMAMCore
import SwiftUI

/// Shows which high-res sources stand behind the proxies or timeline the user picked.
struct RecallView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let report: RecallReport

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(report.title)
                .font(.headline)
                .padding(16)
            Divider()
            List(report.rows) { row in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: row.asset == nil ? "questionmark.circle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(row.asset == nil ? Color.orange : Color.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.name).fontWeight(.medium)
                        Text(row.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    Spacer()
                    if let asset = row.asset {
                        Button("Show") {
                            model.selectedID = asset.id
                            dismiss()
                        }
                        Button("Reveal") { model.revealInFinder(asset.sourcePath) }
                    }
                }
                .controlSize(.small)
                .padding(.vertical, 2)
            }
            Divider()
            HStack {
                if report.relinkedText != nil {
                    Button("Save Timeline Linked to Sources…") { model.saveRelinkedTimeline(report) }
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(minWidth: 640, minHeight: 380)
    }
}
