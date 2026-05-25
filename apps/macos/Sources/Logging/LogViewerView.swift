// LogViewerView.swift — in-app log viewer. Tails the file written by
// LogFileMirror; filters by level; copy + reveal-in-Finder buttons.
import AppKit
import SwiftUI

public struct LogViewerView: View {
    @State private var lines: [String] = []
    @State private var filterLevel: LogLevel = .debug
    @State private var refreshTimer: Timer?

    private let logURL: URL

    public init(logURL: URL = LogFileMirror.shared.currentLogURL) {
        self.logURL = logURL
    }

    public var body: some View {
        VStack(spacing: 8) {
            HStack {
                Picker("Level", selection: $filterLevel) {
                    ForEach(LogLevel.allCases, id: \.self) { level in
                        Text(level.rawValue.capitalized).tag(level)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 360)
                Spacer()
                Button("Copy") { copyToClipboard() }
                Button("Reveal in Finder") { revealInFinder() }
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(filteredLines.indices, id: \.self) { idx in
                        Text(filteredLines[idx])
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(4)
            }
            .background(Color(NSColor.textBackgroundColor))
            .cornerRadius(6)
        }
        .padding()
        .frame(minWidth: 600, minHeight: 360)
        .onAppear {
            reload()
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
                reload()
            }
        }
        .onDisappear {
            refreshTimer?.invalidate()
            refreshTimer = nil
        }
    }

    private var filteredLines: [String] {
        let needle = "[\(filterLevel.rawValue.uppercased())]"
        if filterLevel == .debug { return lines }  // show everything ≥ debug = all
        return lines.filter { line in
            // Show lines at or above the chosen level.
            for level in LogLevel.allCases where level >= filterLevel {
                if line.contains("[\(level.rawValue.uppercased())]") { return true }
            }
            return line.contains(needle)
        }
    }

    private func reload() {
        guard FileManager.default.fileExists(atPath: logURL.path),
            let data = try? Data(contentsOf: logURL),
            let text = String(data: data, encoding: .utf8)
        else {
            lines = []
            return
        }
        // Keep only the last 1000 lines so the UI stays responsive.
        let all = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        lines = Array(all.suffix(1_000))
    }

    private func copyToClipboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(filteredLines.joined(separator: "\n"), forType: .string)
    }

    private func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([logURL])
    }
}
