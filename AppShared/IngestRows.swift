import StradaMAMCore
import SwiftUI

/// One clip in an ingest queue: its name, what is happening to it, and how far along it is.
/// Shared by the MAM app's Watch Folders page and the ingest app.
struct IngestItemRow<Actions: View>: View {
    let item: IngestItem
    let detail: String
    var progress: Double?
    var isProblem = false
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.fileName).lineLimit(1).truncationMode(.middle)
                Text(detail).font(.caption).foregroundStyle(isProblem ? Color.red : Color.secondary)
                    .lineLimit(2)
                if let progress { ProgressView(value: progress).controlSize(.small) }
            }
            Spacer()
            actions
        }
    }
}

extension IngestItemRow where Actions == EmptyView {
    init(item: IngestItem, detail: String, progress: Double? = nil, isProblem: Bool = false) {
        self.init(item: item, detail: detail, progress: progress, isProblem: isProblem) { EmptyView() }
    }
}

/// A number with what it counts underneath, for the row of totals above a queue.
struct IngestCount: View {
    let value: Int
    let label: String

    var body: some View {
        VStack(alignment: .leading) {
            Text("\(value)").font(.title2.monospacedDigit())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}
