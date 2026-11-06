import SwiftUI

/// One row of the Logs pane: a log line, or a run of identical lines collapsed together.
struct LogEntry: Identifiable, Equatable {
    let id: Int
    let first: Date
    var last: Date
    let category: String     // "session", "auth", "pair", … (from "[session] …"), or "app"
    let message: String
    var count: Int

    var isProblem: Bool {
        let m = message.lowercased()
        return ["fail", "error", "couldn't", "refus", "not accepted", "blocked", "expired", "congested", "timed out"]
            .contains { m.contains($0) }
    }

    private static let stampFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    /// Parses "2026-11-05 22:55:47.978 [session] status failed: …" lines, oldest first, and collapses
    /// consecutive repeats of the same message (status polls write the same line every few seconds).
    static func parse(_ lines: [String]) -> [LogEntry] {
        var result: [LogEntry] = []
        for line in lines {
            guard line.count > 24, let date = stampFormat.date(from: String(line.prefix(23))) else {
                // A wrapped continuation or a malformed line: attach to the previous entry's text is overkill; show as-is.
                result.append(LogEntry(id: result.count, first: .distantPast, last: .distantPast, category: "app",
                                       message: line, count: 1))
                continue
            }
            var rest = line.dropFirst(24)
            var category = "app"
            if rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
                category = String(rest[rest.index(after: rest.startIndex)..<close])
                rest = rest[rest.index(after: close)...].drop(while: { $0 == " " })
            }
            let message = String(rest)
            if let lastIndex = result.indices.last,
               result[lastIndex].category == category, result[lastIndex].message == message {
                result[lastIndex].count += 1
                result[lastIndex].last = date
            } else {
                result.append(LogEntry(id: result.count, first: date, last: date, category: category,
                                       message: message, count: 1))
            }
        }
        return result
    }

    /// The line as it is in the file (with a repeat count), for copying.
    var plainText: String {
        let stamp = first == .distantPast ? "" : Self.stampFormat.string(from: last) + " "
        let repeats = count > 1 ? " (×\(count) since \(Self.stampFormat.string(from: first)))" : ""
        return "\(stamp)[\(category)] \(message)\(repeats)"
    }
}

/// What the app has been doing, from its log file: every start, stop, pairing step and the exact error
/// TrueCloud sent back. Newest first, repeats collapsed. Shown from the account menu.
struct LogsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [LogEntry] = []
    @State private var search = ""
    @State private var category = "All"
    @State private var problemsOnly = false
    @State private var confirmClear = false

    private var categories: [String] { ["All"] + Set(entries.map(\.category)).sorted() }

    private var shown: [LogEntry] {
        entries.reversed().filter { e in
            (category == "All" || e.category == category) &&
            (!problemsOnly || e.isProblem) &&
            (search.isEmpty || e.message.localizedCaseInsensitiveContains(search) ||
             e.category.localizedCaseInsensitiveContains(search))
        }
    }

    private var shownText: String { shown.map(\.plainText).joined(separator: "\n") }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Logs")
                .navigationBarTitleDisplayMode(.inline)
                .searchable(text: $search, prompt: "Search logs")
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { Button("Done") { dismiss() } }
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        ShareLink(item: shownText) { Image(systemName: "square.and.arrow.up") }
                            .disabled(shown.isEmpty)
                        Menu {
                            Picker("Category", selection: $category) {
                                ForEach(categories, id: \.self) { Text($0 == "All" ? "All categories" : $0.capitalized).tag($0) }
                            }
                            Toggle("Problems only", systemImage: "exclamationmark.triangle", isOn: $problemsOnly)
                            Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = shownText }
                                .disabled(shown.isEmpty)
                            Divider()
                            Button("Clear Log…", systemImage: "trash", role: .destructive) { confirmClear = true }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                }
                .task {
                    // Live while the sheet is open.
                    while !Task.isCancelled {
                        let fresh = LogEntry.parse(Log.recentLines(3000))
                        if fresh != entries { entries = fresh }
                        try? await Task.sleep(for: .seconds(2))
                    }
                }
                .confirmationDialog("Clear the log?", isPresented: $confirmClear, titleVisibility: .visible) {
                    Button("Clear", role: .destructive) { Log.clear(); entries = [] }
                } message: {
                    Text("This empties the log. It can't be undone.")
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        if shown.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "doc.text.magnifyingglass").font(.system(size: 34)).foregroundStyle(.secondary)
                Text(entries.isEmpty ? "Nothing logged yet" : "No matches").font(.title3.weight(.semibold))
                Text(entries.isEmpty
                     ? "Starts, stops, pairing and errors show up here as they happen."
                     : "Try another search, category, or turn off Problems only.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(shown) { entry in
                LogRow(entry: entry)
                    .contextMenu { Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = entry.plainText } }
            }
            .listStyle(.plain)
        }
    }
}

private struct LogRow: View {
    let entry: LogEntry

    private static let time: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()
    private static let day: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "d MMM"; return f
    }()

    private var stamp: String {
        guard entry.first != .distantPast else { return "" }
        let t = Self.time.string(from: entry.last)
        return Calendar.current.isDateInToday(entry.last) ? t : "\(Self.day.string(from: entry.last)) \(t)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if entry.isProblem {
                    Image(systemName: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                }
                Text(entry.category)
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
                Spacer(minLength: 0)
                Text(stamp).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
            }
            Text(entry.message)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            if entry.count > 1 {
                Text("Repeated \(entry.count)\u{00D7} since \(Self.time.string(from: entry.first))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
