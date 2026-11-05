import SwiftUI

struct LogsView: View {
    let model: ServerViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Activity log").font(.title2.weight(.semibold))
                    Text("Connection checks, commands, and the Linux user service journal.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Fetch Voxl Logs") { model.perform(.logs) }.disabled(model.busy)
                Button("Clear", action: model.clearLogs).disabled(model.logs.isEmpty)
            }
            if model.logs.isEmpty {
                ContentUnavailableView("No activity yet", systemImage: "text.alignleft",
                                       description: Text("Refresh the status or fetch the service journal."))
            } else {
                List(model.logs.reversed()) { entry in
                    DisclosureGroup {
                        Text(entry.message).font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 5)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: entry.isError ? "exclamationmark.circle" : "info.circle")
                                .foregroundStyle(entry.isError ? Color.orange : Color.secondary)
                            Text(entry.message.components(separatedBy: "\n").first ?? "")
                                .lineLimit(1)
                            Spacer()
                            Text(entry.date, style: .time).font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .padding(24)
    }
}
