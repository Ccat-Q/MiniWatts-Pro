import SwiftUI
import UIKit

nonisolated struct ReportFiles: Identifiable, Sendable {
    let id = UUID()
    let directory: URL
    let urls: [URL]
}

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
                var records: [ChargeSession] = []
                for (index, summary) in sessions.enumerated() {
                    try Task.checkCancellation()
                    let loaded = summary.samples.isEmpty ? try await monitor.loadSession(summary.id) : summary
                    records.append(loaded)
                    progress = Double(index + 1) / Double(sessions.count) * 0.25
                }
                try Task.checkCancellation()
                let captured = records
                let exportWorker = Task.detached(priority: .userInitiated) {
                    try ReportGenerator.generate(captured, pdf: pdf, lower: lower, upper: upper, single: single,
                                                 generated: generated, version: version, timezone: timezone) { value in
                        Task { @MainActor [weak self] in
                            if self?.generation == token { self?.progress = 0.25 + value * 0.75 }
                        }
                    }
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
            if let error = export.error { Text(verbatim: error).font(.caption).foregroundStyle(Color.mwDanger) }
        }
        .sheet(item: $export.files, onDismiss: { export.clean() }) { files in
            ReportShareSheet(urls: files.urls) { export.clean() }
        }
        .onDisappear { export.cancel() }
    }
    private func start(pdf: Bool) {
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

nonisolated enum ReportGenerator {
    static func generate(_ sessions: [ChargeSession], pdf: Bool, lower: Int, upper: Int, single: Bool,
                         generated: Date, version: String, timezone: String,
                         progress: @Sendable (Double) -> Void) throws -> ReportFiles {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MiniWattsPro-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            try Task.checkCancellation()
            if pdf {
                let url = directory.appendingPathComponent("MiniWattsPro-report.pdf")
                try PDFReport.write(sessions, to: url, lower: lower, upper: upper, single: single,
                                    generated: generated, version: version, timezone: timezone, progress: progress)
                try Task.checkCancellation()
                return ReportFiles(directory: directory, urls: [url])
            }
            let summaries = directory.appendingPathComponent("MiniWattsPro-sessions.csv")
            let samples = directory.appendingPathComponent("MiniWattsPro-samples.csv")
            FileManager.default.createFile(atPath: summaries.path, contents: Data([0xEF, 0xBB, 0xBF]))
            FileManager.default.createFile(atPath: samples.path, contents: Data([0xEF, 0xBB, 0xBF]))
            let summaryFile = try FileHandle(forWritingTo: summaries)
            let sampleFile = try FileHandle(forWritingTo: samples)
            defer { try? summaryFile.close(); try? sampleFile.close() }
            try summaryFile.seekToEnd(); try sampleFile.seekToEnd()
            try summaryFile.write(contentsOf: Data(ReportCSV.row(ReportCSV.summaryHeader).utf8))
            try sampleFile.write(contentsOf: Data(ReportCSV.row(ReportCSV.sampleHeader).utf8))
            for (index, session) in sessions.enumerated() {
                try Task.checkCancellation()
                try summaryFile.write(contentsOf: Data(ReportCSV.summary(session, generated: generated, appVersion: version, timezone: timezone).utf8))
                for (sampleIndex, sample) in session.samples.enumerated() {
                    if sampleIndex.isMultiple(of: 256) { try Task.checkCancellation() }
                    try sampleFile.write(contentsOf: Data(ReportCSV.sample(sample, in: session).utf8))
                }
                progress(Double(index + 1) / Double(sessions.count))
            }
            return ReportFiles(directory: directory, urls: [summaries, samples])
        } catch { try? FileManager.default.removeItem(at: directory); throw error }
    }
}

nonisolated enum PDFReport {
    private static func text(_ key: String.LocalizationValue) -> String { String(localized: key) }
    static func write(_ sessions: [ChargeSession], to url: URL, lower: Int, upper: Int, single: Bool,
                      generated: Date, version: String, timezone: String, progress: @Sendable (Double) -> Void) throws {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595, height: 842))
        try renderer.writePDF(to: url) { context in
            let page = PDFPage(context: context)
            page.newPage()
            page.line("MiniWatts Pro", size: 24, bold: true)
            page.line(single ? text("Charge report") : text("Charge range report"), size: 18, bold: true)
            page.line(text("Generated") + ": " + generated.formatted(date: .numeric, time: .standard) + " · " + timezone)
            page.line(text("App version") + ": " + version)
            page.line(text("Includes complete sessions selected by start time. Missing readings are shown as dashes."))
            let summaries = sessions.map { $0.summary() }
            let totals = AnalysisTotals(sessions: summaries)
            page.line(text("Sessions") + ": " + String(sessions.count))
            page.line(text("Delivered") + ": " + amount(totals.inputWh, "Wh") + "    " + text("Stored") + ": " + amount(totals.batteryWh, "Wh"))
            page.line(text("Cell share") + ": " + amount(totals.cellShare, "%") + "    " + text("Load + loss") + ": " + amount(totals.loadAndLossWh, "Wh"))
            page.line(text("Average in") + ": " + amount(totals.averageInputWatts, "W") + "    " + text("Average cell") + ": " + amount(totals.averageBatteryWatts, "W"))
            page.line(text("Observation coverage") + ": " + amount(totals.coverage * 100, "%"))
            page.line(text("Load + loss includes phone consumption and conversion loss. Thermal pressure does not prove a cause of slow charging."))
            if single, let session = sessions.first {
                page.line(text("Device model") + ": " + session.deviceModel + " · " + session.systemVersion)
                page.line(session.levelDescription + " · " + text("Target") + ": \(session.targetPercent)%")
                page.line(text("Started") + ": " + session.start.formatted(date: .numeric, time: .shortened))
                page.line(text("Ended") + ": " + (session.end?.formatted(date: .numeric, time: .shortened) ?? "—"))
                page.line(text("Average cell temp") + ": " + amount(summaries[0].averageBatteryTemperature, "°C") + "    " + text("Peak cell temp") + ": " + amount(session.peakBatteryTemperature, "°C"))
                page.line(text("System thermal pressure") + ": " + duration(session.throttledSeconds))
                page.line(text("Peak from charger") + ": " + amount(session.totals.inputMeasuredSeconds > 0 ? session.peakInputWatts : nil, "W"))
                page.line(text("Peak into cell") + ": " + amount(session.totals.batteryMeasuredSeconds > 0 ? session.peakBatteryWatts : nil, "W"))
                if session.interrupted { page.line(text("Recording was interrupted. The end is the last observed time.")) }
                page.line(text("Samples") + ": \(session.samples.count) · " + text("Input measured") + ": " + duration(session.totals.inputMeasuredSeconds) + " · " + text("Battery measured") + ": " + duration(session.totals.batteryMeasuredSeconds))
                page.chart(session.samples, title: text("Power (W) — input / battery"), first: \.inputWatts, second: \.batteryWatts)
                page.chart(session.samples, title: text("Charge level (%)"), first: { $0.percent.map(Double.init) }, second: { _ in nil })
                page.chart(session.samples, title: text("Battery temperature (°C)"), first: \.batteryTemperature, second: { _ in nil })
                progress(1)
            } else {
                page.line(text("Comparable charge range") + ": \(lower)%–\(upper)%", size: 16, bold: true)
                for wireless in [false, true] {
                    if Task.isCancelled { return }
                    page.line(wireless ? text("Wireless comparison") : text("Wired comparison"), size: 14, bold: true)
                    let matching = summaries.filter { $0.isWireless == wireless }
                    let ranked = matching.compactMap { session -> (ChargeSession, Double)? in
                        ChargeAnalysis.comparableSeconds(session, from: lower, to: upper).map { (session, $0) }
                    }.sorted { $0.1 < $1.1 }
                    if ranked.count < 2 { page.line(text("Not enough comparable sessions yet.")) }
                    for (session, seconds) in ranked {
                        if Task.isCancelled { return }
                        page.line(session.start.formatted(date: .numeric, time: .shortened) + " · " + duration(seconds) + " · " + session.deviceModel)
                    }
                    page.line(text("Excluded records") + ": \(matching.count - ranked.count) · " + text("Incomplete range or insufficient coverage"))
                }
                page.line(text("Sessions"), size: 16, bold: true)
                for (index, s) in summaries.enumerated() {
                    if Task.isCancelled { return }
                    page.line(s.start.formatted(date: .numeric, time: .shortened) + " · " + s.levelDescription + " · " + duration(s.duration), bold: true)
                    page.line(s.deviceModel + " · " + s.systemVersion + " · " + text("Target") + ": \(s.targetPercent)% · " + (s.isWireless ? text("Wireless") : text("Wired")))
                    page.line(text("Stored") + ": " + amount(s.measuredBatteryWattHours, "Wh") + " · " + text("Delivered") + ": " + amount(s.totals.measuredInputWattHours, "Wh") + " · " + text("Observation coverage") + ": " + amount(s.coverage * 100, "%"))
                    page.line(text("Cell share") + ": " + amount(s.totals.chargePathEfficiencyPercent, "%") + " · " + text("Average cell temp") + ": " + amount(s.averageBatteryTemperature, "°C"))
                    if s.interrupted { page.line(text("Recording was interrupted. The end is the last observed time.")) }
                    progress(Double(index + 1) / Double(summaries.count))
                }
            }
        }
    }
    private static func amount(_ value: Double?, _ unit: String) -> String {
        guard let value, value.isFinite else { return "—" }
        return value.formatted(.number.precision(.fractionLength(1))) + " " + unit
    }
    private static func duration(_ seconds: Double) -> String {
        DateComponentsFormatter.localizedString(from: DateComponents(hour: Int(seconds) / 3600, minute: Int(seconds) % 3600 / 60, second: Int(seconds) % 60), unitsStyle: .abbreviated) ?? "—"
    }
}

private nonisolated final class PDFPage {
    let context: UIGraphicsPDFRendererContext
    var y: CGFloat = 42
    var page = 0
    init(context: UIGraphicsPDFRendererContext) { self.context = context }
    func newPage() {
        context.beginPage(); y = 42; page += 1
        ("MiniWatts Pro · \(page)" as NSString).draw(at: CGPoint(x: 42, y: 812),
                    withAttributes: [.font: UIFont.systemFont(ofSize: 9), .foregroundColor: UIColor.darkGray])
    }
    func line(_ text: String, size: CGFloat = 11, bold: Bool = false) {
        let attributes: [NSAttributedString.Key: Any] = [.font: bold ? UIFont.boldSystemFont(ofSize: size) : UIFont.systemFont(ofSize: size), .foregroundColor: UIColor.black]
        let height = max(size + 4, (text as NSString).boundingRect(with: CGSize(width: 511, height: 1000), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes, context: nil).height)
        if y + height > 790 { newPage() }
        (text as NSString).draw(in: CGRect(x: 42, y: y, width: 511, height: height + 2), withAttributes: attributes)
        y += height + 7
    }
    func chart(_ samples: [ChargeSample], title: String, first: @escaping (ChargeSample) -> Double?, second: @escaping (ChargeSample) -> Double?) {
        if y + 170 > 790 { newPage() }
        line(title, size: 12, bold: true)
        let rect = CGRect(x: 42, y: y + 8, width: 511, height: 100)
        let values = (samples.compactMap(first) + samples.compactMap(second)).filter(\.isFinite)
        guard let minValue = values.min(), let maxValue = values.max() else { line(String(localized: "No reading")); return }
        let low = min(0, minValue), high = max(maxValue, low + 1)
        let end = max(samples.last?.offset ?? 0, 1)
        let cg = context.cgContext
        cg.setStrokeColor(UIColor.lightGray.cgColor); cg.stroke(rect)
        for (read, color) in [(first, UIColor.systemTeal), (second, UIColor.systemOrange)] {
            cg.setStrokeColor(color.cgColor); cg.setLineWidth(1)
            var previous: ChargeSample?
            var drawing = false
            for (index, sample) in samples.enumerated() {
                if index.isMultiple(of: 256), Task.isCancelled { return }
                if sample.startsNewObservation || (previous.map { sample.offset - $0.offset > 10 } ?? false) {
                    cg.strokePath(); drawing = false
                }
                previous = sample
                guard let value = read(sample), value.isFinite else { cg.strokePath(); drawing = false; continue }
                let point = CGPoint(x: rect.minX + CGFloat(sample.offset / end) * rect.width,
                                    y: rect.maxY - CGFloat((value - low) / (high - low)) * rect.height)
                if drawing { cg.addLine(to: point) } else { cg.move(to: point); drawing = true }
            }
            cg.strokePath()
        }
        y = rect.maxY + 6
        line(String(format: "%.1f – %.1f · 0 – %.0f s", low, high, end), size: 9)
    }
}
