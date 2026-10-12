import SwiftUI
import UIKit

/// Each export owns a private directory and a frozen selection of complete records.
@Observable final class ReportExportController {
    var progress: Double = 0
    var running = false
    var error: String?
    var files: ReportFiles?
    private var task: Task<Void, Never>?
    private var worker: Task<ReportFiles, Error>?
    private var generation: UUID?
    private var directory: URL?

    func start(sessions: [ChargeSession], monitor: PowerMonitor, pdf: Bool, lower: Int, upper: Int, single: Bool) {
        guard !running, !sessions.isEmpty else { return }
        clean()
        let token = UUID()
        generation = token; running = true; progress = 0; error = nil
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let generated = Date.now
        let timezone = TimeZone.current.identifier
        task = Task {
            do {
                let captured: [ChargeSession]
                if pdf && single, let summary = sessions.first {
                    captured = [summary.samples.isEmpty ? try await monitor.loadSession(summary.id) : summary]
                } else { captured = sessions }
                try Task.checkCancellation()
                let exportWorker = Task.detached(priority: .userInitiated) {
                    let reportProgress: @Sendable (Double) -> Void = { value in
                        Task { @MainActor [weak self] in
                            if self?.generation == token { self?.progress = value }
                        }
                    }
                    if pdf {
                        return try ReportGenerator.generate(captured, pdf: true, lower: lower, upper: upper, single: single,
                                                            generated: generated, version: version, timezone: timezone, progress: reportProgress)
                    }
                    return try await ReportGenerator.generateCSV(captured, generated: generated, version: version, timezone: timezone,
                                                                 lower: lower, upper: upper, load: { summary in
                        summary.samples.isEmpty ? try await monitor.loadSession(summary.id) : summary
                    }, progress: reportProgress)
                }
                worker = exportWorker
                let result = try await exportWorker.value
                guard !Task.isCancelled, generation == token else {
                    try? FileManager.default.removeItem(at: result.directory)
                    return
                }
                directory = result.directory; files = result; running = false; progress = 1; worker = nil
            } catch {
                if generation == token {
                    running = false; worker = nil
                    if !(error is CancellationError) { self.error = error.localizedDescription }
                }
            }
        }
    }
    func cancel() {
        generation = nil; task?.cancel(); worker?.cancel(); running = false
    }
    func clean() {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
        files = nil
    }
}

struct ReportExportButton: View {
    let sessions: [ChargeSession]
    let lower: Int
    let upper: Int
    let isSingle: Bool
    @Environment(PowerMonitor.self) private var monitor
    @State private var export = ReportExportController()
    @State private var lastWasPDF = true
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if export.running {
                ProgressView("Generating report…", value: export.progress)
                Button("Cancel") { export.cancel() }
            } else {
                Menu {
                    Button("Export PDF report") { start(pdf: true) }
                    Button("Export CSV tables") { start(pdf: false) }
                } label: { Label("Export report", systemImage: "square.and.arrow.up") }
                    .disabled(sessions.isEmpty || !monitor.isLoaded)
            }
            if let error = export.error {
                Text(verbatim: error).font(.caption).foregroundStyle(Color.mwDanger)
                Button("Retry") { start(pdf: lastWasPDF) }
            }
        }
        .sheet(item: $export.files, onDismiss: { export.clean() }) { files in
            ReportShareSheet(urls: files.urls) { export.clean() }
        }
        .onDisappear { export.cancel() }
    }
    private func start(pdf: Bool) {
        lastWasPDF = pdf
        export.start(sessions: sessions, monitor: monitor, pdf: pdf, lower: lower, upper: upper, single: isSingle)
    }
}

struct ReportShareSheet: UIViewControllerRepresentable {
    let urls: [URL]
    let completion: () -> Void
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: urls, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in Task { @MainActor in completion() } }
        return controller
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
