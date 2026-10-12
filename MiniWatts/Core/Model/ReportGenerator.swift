import Foundation
import UIKit

nonisolated struct ReportFiles: Identifiable, Sendable {
    let id = UUID()
    let directory: URL
    let urls: [URL]
}

nonisolated enum ReportGenerator {
    static func generate(_ sessions: [ChargeSession], pdf: Bool, lower: Int, upper: Int, single: Bool,
                         generated: Date, version: String, timezone: String,
                         progress: @Sendable (Double) -> Void) throws -> ReportFiles {
        guard !sessions.isEmpty else {
            throw NSError(domain: "MiniWattsPro.Report", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: String(localized: "No records to export")])
        }
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
            let writer = try CSVReportWriter(directory: directory)
            defer { writer.close() }
            for (index, session) in sessions.enumerated() {
                try writer.append(session, generated: generated, version: version, timezone: timezone, lower: lower, upper: upper)
                progress(Double(index + 1) / Double(sessions.count))
            }
            try Task.checkCancellation()
            return ReportFiles(directory: directory, urls: writer.urls)
        } catch { try? FileManager.default.removeItem(at: directory); throw error }
    }

    /// Finished session files are immutable. Load one at a time and fail if the frozen selection changed.
    static func generateCSV(_ snapshots: [ChargeSession], generated: Date, version: String, timezone: String,
                            lower: Int, upper: Int, load: @Sendable (ChargeSession) async throws -> ChargeSession,
                            progress: @Sendable (Double) -> Void) async throws -> ReportFiles {
        guard !snapshots.isEmpty else {
            throw NSError(domain: "MiniWattsPro.Report", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: String(localized: "No records to export")])
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MiniWattsPro-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            try Task.checkCancellation()
            let writer = try CSVReportWriter(directory: directory)
            defer { writer.close() }
            for (index, snapshot) in snapshots.enumerated() {
                try Task.checkCancellation()
                let record = try await load(snapshot)
                guard record.id == snapshot.id, record.end == snapshot.end, record.lastObserved == snapshot.lastObserved,
                      record.samples.count == (snapshot.samples.isEmpty ? snapshot.sampleCount : snapshot.samples.count) else {
                    throw NSError(domain: "MiniWattsPro.Report", code: 2,
                                  userInfo: [NSLocalizedDescriptionKey: String(localized: "Selected history changed. Retry export.")])
                }
                try writer.append(record, generated: generated, version: version, timezone: timezone, lower: lower, upper: upper)
                progress(Double(index + 1) / Double(snapshots.count))
            }
            try Task.checkCancellation()
            return ReportFiles(directory: directory, urls: writer.urls)
        } catch { try? FileManager.default.removeItem(at: directory); throw error }
    }
}

private nonisolated final class CSVReportWriter {
    let urls: [URL]
    private let summaryFile: FileHandle
    private let sampleFile: FileHandle
    init(directory: URL) throws {
        let summaries = directory.appendingPathComponent("MiniWattsPro-sessions.csv")
        let samples = directory.appendingPathComponent("MiniWattsPro-samples.csv")
        try Data([0xEF, 0xBB, 0xBF]).write(to: summaries)
        try Data([0xEF, 0xBB, 0xBF]).write(to: samples)
        urls = [summaries, samples]
        summaryFile = try FileHandle(forWritingTo: summaries)
        sampleFile = try FileHandle(forWritingTo: samples)
        try summaryFile.seekToEnd(); try sampleFile.seekToEnd()
        try summaryFile.write(contentsOf: Data(ReportCSV.row(ReportCSV.localizedHeader(ReportCSV.summaryHeader)).utf8))
        try sampleFile.write(contentsOf: Data(ReportCSV.row(ReportCSV.localizedHeader(ReportCSV.sampleHeader)).utf8))
    }
    func append(_ session: ChargeSession, generated: Date, version: String, timezone: String, lower: Int, upper: Int) throws {
        try Task.checkCancellation()
        try summaryFile.write(contentsOf: Data(ReportCSV.summary(session, generated: generated, appVersion: version,
                                                                timezone: timezone, lower: lower, upper: upper).utf8))
        for (index, sample) in session.samples.enumerated() {
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            try sampleFile.write(contentsOf: Data(ReportCSV.sample(sample, in: session).utf8))
        }
    }
    func close() { try? summaryFile.close(); try? sampleFile.close() }
}

nonisolated enum PDFReport {
    private static func text(_ key: String.LocalizationValue) -> String { String(localized: key) }
    static func write(_ sessions: [ChargeSession], to url: URL, lower: Int, upper: Int, single: Bool,
                      generated: Date, version: String, timezone: String, progress: @Sendable (Double) -> Void) throws {
        let dates = DateFormatter()
        dates.locale = .current
        dates.timeZone = TimeZone(identifier: timezone) ?? .current
        dates.dateStyle = .medium
        dates.timeStyle = .medium
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595, height: 842))
        try renderer.writePDF(to: url) { context in
            let page = PDFPage(context: context)
            page.newPage()
            page.line("MiniWatts Pro", size: 24, bold: true)
            page.line(single ? text("Charge report") : text("Charge range report"), size: 18, bold: true)
            page.line(text("Generated") + ": " + dates.string(from: generated) + " · " + timezone)
            page.line(text("App version") + ": " + version)
            page.line(text("Includes complete sessions selected by start time. Missing readings are shown as dashes."))
            let summaries = sessions.map { $0.summary() }
            let totals = AnalysisTotals(sessions: summaries)
            page.line(text("Sessions") + ": " + String(sessions.count))
            page.line(text("Delivered") + ": " + amount(totals.inputWh, "Wh") + "    " + text("Stored") + ": " + amount(totals.batteryWh, "Wh"))
            page.line(text("Conversion efficiency") + ": " + amount(totals.cellShare, "%") + "    " + text("Load + loss") + ": " + amount(totals.loadAndLossWh, "Wh"))
            page.line(text("Paired cell Wh ÷ input Wh") + ". " + text("The share of measured input reaching the cell. Phone load and conversion loss affect this ratio."))
            page.line(text("Average in") + ": " + amount(totals.averageInputWatts, "W") + "    " + text("Average cell") + ": " + amount(totals.averageBatteryWatts, "W"))
            page.line(text("Observation coverage") + ": " + amount(totals.coverage * 100, "%"))
            page.line(text("Average cell temp") + ": " + amount(totals.averageTemperature, "°C"))
            page.line(text("Load + loss includes phone consumption and conversion loss. Thermal pressure does not prove a cause of slow charging."))
            page.line(text("Targets are used for estimates only. Remaining time uses observed percentage trends and comparable history; it is not a charging limit or a guaranteed completion time."))
            if single, let session = sessions.first {
                page.line(text("Device model") + ": " + session.deviceModel + " · " + session.systemVersion)
                page.line(session.isWireless ? text("Wireless") : text("Wired"))
                page.line(session.levelDescription + " · " + text("Target") + ": \(session.targetPercent)%")
                page.line(text("Started") + ": " + dates.string(from: session.start))
                page.line(text("Ended") + ": " + (session.end.map { dates.string(from: $0) } ?? "—"))
                page.line(text("Average cell temp") + ": " + amount(summaries[0].averageBatteryTemperature, "°C") + "    " + text("Peak cell temp") + ": " + amount(session.peakBatteryTemperature, "°C"))
                page.line(text("System thermal pressure") + ": " + duration(session.throttledSeconds))
                page.line(text("Peak from charger") + ": " + amount(session.totals.inputMeasuredSeconds > 0 ? session.peakInputWatts : nil, "W"))
                page.line(text("Peak into cell") + ": " + amount(session.totals.batteryMeasuredSeconds > 0 ? session.peakBatteryWatts : nil, "W"))
                if session.interrupted { page.line(text("Recording was interrupted. The end is the last observed time.")) }
                page.line(text("Samples") + ": \(session.samples.count) · " + text("Input measured") + ": " + duration(session.totals.inputMeasuredSeconds) + " · " + text("Battery measured") + ": " + duration(session.totals.batteryMeasuredSeconds))
                page.chart(session.samples, title: text("Power (W) — input / battery"), first: \.inputWatts, second: \.batteryWatts)
                page.chart(session.samples, title: text("Charge level (%)"), first: { $0.percent.map(Double.init) }, second: { _ in nil })
                page.chart(session.samples, title: text("Battery temperature (°C)"), first: \.batteryTemperature, second: { _ in nil }, zeroBaseline: false)
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
                        page.line(dates.string(from: session.start) + " · " + duration(seconds) + " · " + session.deviceModel)
                        if let m = ChargeAnalysis.comparableMetrics(session, from: lower, to: upper) {
                            page.line(text("Average in / cell") + ": " + amount(m.totals.averageInputWatts, "W") + " / " + amount(m.averageBatteryWatts, "W"))
                            page.line(text("Recorded peak in / cell") + ": " + amount(m.peakInputWatts, "W") + " / " + amount(m.peakBatteryWatts, "W"))
                            page.line(text("Delivered / stored") + ": " + amount(m.totals.measuredInputWattHours, "Wh") + " / " + amount(m.batteryWh, "Wh"))
                            page.line(text("Efficiency / load + loss") + ": " + amount(m.totals.chargePathEfficiencyPercent, "%") + " / " + amount(m.totals.unaccountedWattHours, "Wh"))
                            page.line(text("Average / peak cell temp") + ": " + amount(m.averageTemperature, "°C") + " / " + amount(m.peakTemperature, "°C"))
                            page.line(text("System thermal pressure") + ": " + duration(m.thermalPressureSeconds))
                            page.line(text("Observation / input / battery coverage") + ": " + amount(m.coverage * 100, "%") + " / " + amount(m.totals.inputMeasuredSeconds / m.seconds * 100, "%") + " / " + amount(m.totals.batteryMeasuredSeconds / m.seconds * 100, "%"))
                        }
                    }
                    page.line(text("Excluded records") + ": \(matching.count - ranked.count) · " + text("Incomplete range or insufficient coverage"))
                }
                page.line(text("Comparison values cover the selected charge interval. Recorded peaks and temperature use saved samples."))
                page.line(text("Sessions"), size: 16, bold: true)
                for (index, s) in summaries.enumerated() {
                    if Task.isCancelled { return }
                    page.line(dates.string(from: s.start) + " · " + s.levelDescription + " · " + duration(s.duration), bold: true)
                    page.line(s.deviceModel + " · " + s.systemVersion + " · " + text("Target") + ": \(s.targetPercent)% · " + (s.isWireless ? text("Wireless") : text("Wired")))
                    page.line(text("Stored") + ": " + amount(s.measuredBatteryWattHours, "Wh") + " · " + text("Delivered") + ": " + amount(s.totals.measuredInputWattHours, "Wh") + " · " + text("Observation coverage") + ": " + amount(s.coverage * 100, "%"))
                    page.line(text("Session efficiency") + ": " + amount(s.totals.chargePathEfficiencyPercent, "%") + " · " + text("Average cell temp") + ": " + amount(s.averageBatteryTemperature, "°C"))
                    page.line(text("Average in") + ": " + amount(s.totals.averageInputWatts, "W") + " · " + text("Average cell") + ": " + amount(s.averageBatteryWatts, "W"))
                    page.line(text("Peak from charger") + ": " + amount(s.totals.inputMeasuredSeconds > 0 ? s.peakInputWatts : nil, "W") + " · " + text("Peak into cell") + ": " + amount(s.totals.batteryMeasuredSeconds > 0 ? s.peakBatteryWatts : nil, "W"))
                    page.line(text("System thermal pressure") + ": " + duration(s.throttledSeconds) + " · " + text("Input measured") + ": " + duration(s.totals.inputMeasuredSeconds) + " · " + text("Battery measured") + ": " + duration(s.totals.batteryMeasuredSeconds))
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
    func chart(_ samples: [ChargeSample], title: String, first: @escaping (ChargeSample) -> Double?, second: @escaping (ChargeSample) -> Double?, zeroBaseline: Bool = true) {
        if y + 170 > 790 { newPage() }
        line(title, size: 12, bold: true)
        let rect = CGRect(x: 42, y: y + 8, width: 511, height: 100)
        let values = (samples.compactMap(first) + samples.compactMap(second)).filter(\.isFinite)
        guard let minValue = values.min(), let maxValue = values.max() else { line(String(localized: "No reading")); return }
        let padding = max((maxValue - minValue) * 0.1, 1)
        let low = zeroBaseline ? min(0, minValue) : minValue - padding
        let high = zeroBaseline ? max(maxValue, low + 1) : maxValue + padding
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
