import Foundation
import PDFKit
import UIKit

/// Runs against the real UIKit report renderer in an iOS simulator on Actions.
@main struct ReportTests {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }
    static func session() -> ChargeSession {
        var s = ChargeSession(start: Date(timeIntervalSince1970: 1_000), startPercent: 19,
                              adapterName: "Adapter, \"quoted\"", adapterRatedWatts: 30, isWireless: false)
        s.deviceModel = "iPhone-test"; s.systemVersion = "iOS-test"; s.endPercent = 100
        for offset in stride(from: 0, through: 4860, by: 5) {
            var totals = EnergyTotals()
            totals.integratedSeconds = Double(offset)
            totals.batteryMeasuredSeconds = Double(offset)
            totals.batteryWattHours = 8 * Double(offset) / 3600
            totals.inputMeasuredSeconds = Double(offset)
            totals.inputWattHours = 10 * Double(offset) / 3600
            totals.pairedInputWattHours = totals.inputWattHours
            totals.pairedBatteryWattHours = totals.batteryWattHours
            s.samples.append(ChargeSample(offset: Double(offset), inputWatts: offset == 300 ? nil : 10,
                batteryWatts: 8, percent: 19 + offset / 60, batteryTemperature: 30, hottestTemperature: 35,
                throttled: false, observedSeconds: Double(offset), energyTotals: totals))
        }
        s.end = s.start.addingTimeInterval(4860); s.lastObserved = s.end!
        s.totals.integratedSeconds = s.duration
        s.totals.inputMeasuredSeconds = s.duration; s.totals.batteryMeasuredSeconds = s.duration
        s.totals.inputWattHours = 13.5; s.totals.batteryWattHours = 10.8
        s.totals.pairedInputWattHours = 13.5; s.totals.pairedBatteryWattHours = 10.8
        s.peakInputWatts = 10; s.peakBatteryWatts = 8; s.peakBatteryTemperature = 30
        return s
    }
    @MainActor static func main() async throws {
        let chinese = CommandLine.arguments.contains("--chinese")
        let records = (0..<70).map { _ in session() }
        let generated = Date(timeIntervalSince1970: 10_000)
        let single = try ReportGenerator.generate([records[0]], pdf: true, lower: 20, upper: 80, single: true,
                          generated: generated, version: "test-version", timezone: "Asia/Shanghai", progress: { _ in })
        defer { try? FileManager.default.removeItem(at: single.directory) }
        guard let pdf = PDFDocument(url: single.urls[0]) else { fatalError("Single PDF must be readable") }
        let text = pdf.string ?? ""
        check(pdf.pageCount >= 2, "Full single report must paginate its three charts")
        check(text.contains("iPhone-test") && text.contains("iOS-test") && text.contains("test-version") && text.contains("Asia/Shanghai"), "PDF context must be present")
        check(text.contains("10:46:40"), "PDF dates must use the timezone captured in the report metadata")
        check(text.contains("13.5 Wh") && text.contains("10.8 Wh") && text.contains("80.0 %"), "PDF totals must match the common analysis model")
        check(text.contains(chinese ? "充电报告" : "Charge report"), "Report language must follow the application bundle")
        let range = try ReportGenerator.generate(records, pdf: true, lower: 20, upper: 80, single: false,
                          generated: generated, version: "test-version", timezone: "UTC", progress: { _ in })
        defer { try? FileManager.default.removeItem(at: range.directory) }
        guard let rangePDF = PDFDocument(url: range.urls[0]) else { fatalError("Range PDF must be readable") }
        check(rangePDF.pageCount > 10, "Long range report must paginate")
        check((rangePDF.string ?? "").contains("945.0 Wh"), "Range aggregate must equal the sum of the selected records")
        let selected = records[0]
        let csv = try await ReportGenerator.generateCSV([selected.summary()], generated: generated,
                          version: "test-version", timezone: "UTC", lower: 20, upper: 80,
                          load: { _ in selected }, progress: { _ in })
        defer { try? FileManager.default.removeItem(at: csv.directory) }
        check(csv.urls.count == 2, "Export must create summary and sample CSV tables")
        let summary = try String(contentsOf: csv.urls[0], encoding: .utf8)
        let samples = try String(contentsOf: csv.urls[1], encoding: .utf8)
        check(summary.contains(chinese ? "会话标识" : "session_id"), "CSV headers must follow the application language")
        check(summary.contains("\"13.5\",\"10.8\",\"80\""), "CSV totals must match PDF and analysis")
        check(summary.contains("Adapter, \"\"quoted\"\""), "Export must escape real adapter names")
        check(samples.components(separatedBy: "\r\n").count == records[0].samples.count + 2, "Every actual sample must be exported")
        check(samples.contains("\"300\",\"24\",\"\",\"8\""), "Missing input must stay empty in sample CSV")
        let selection = Array(records.prefix(2))
        let multiple = try await ReportGenerator.generateCSV(selection.map { $0.summary() }, generated: generated,
                        version: "test-version", timezone: "UTC", lower: 20, upper: 80,
                        load: { snapshot in selection.first { $0.id == snapshot.id }! }, progress: { _ in })
        defer { try? FileManager.default.removeItem(at: multiple.directory) }
        let multipleSamples = try String(contentsOf: multiple.urls[1], encoding: .utf8)
        check(multipleSamples.components(separatedBy: "\r\n").count == selection.reduce(0) { $0 + $1.samples.count } + 2,
              "Streaming multiple sessions must preserve every sample")
        do {
            _ = try await ReportGenerator.generateCSV([records[1].summary()], generated: generated,
                        version: "", timezone: "UTC", lower: 20, upper: 80, load: { _ in selected }, progress: { _ in })
            fatalError("A changed selection must not silently export other data")
        } catch { }
        if let path = ProcessInfo.processInfo.environment["REPORT_TEST_OUTPUT"] {
            let folder = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for (name, source) in [("single.pdf", single.urls[0]), ("range.pdf", range.urls[0]),
                                   ("sessions.csv", csv.urls[0]), ("samples.csv", csv.urls[1])] {
                try FileManager.default.copyItem(at: source, to: folder.appendingPathComponent(name))
            }
            for index in 0..<min(pdf.pageCount, 2) {
                guard let page = pdf.page(at: index), let data = page.thumbnail(of: CGSize(width: 595, height: 842), for: .mediaBox).pngData() else {
                    fatalError("PDF pages must render")
                }
                try data.write(to: folder.appendingPathComponent("single-page-\(index + 1).png"))
            }
            guard let page = rangePDF.page(at: 0), let data = page.thumbnail(of: CGSize(width: 595, height: 842), for: .mediaBox).pngData() else {
                fatalError("Range PDF must render")
            }
            try data.write(to: folder.appendingPathComponent("range-page-1.png"))
        }
        do {
            _ = try ReportGenerator.generate([], pdf: true, lower: 20, upper: 80, single: false,
                        generated: generated, version: "", timezone: "UTC", progress: { _ in })
            fatalError("Empty selection must fail")
        } catch { }
        let before = Set(try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path))
        let cancelled = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try ReportGenerator.generate(records, pdf: false, lower: 20, upper: 80, single: false,
                        generated: generated, version: "", timezone: "UTC", progress: { _ in })
        }
        do { _ = try await cancelled.value; fatalError("Cancellation must be honored") }
        catch is CancellationError { }
        let after = Set(try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path))
        check(after.subtracting(before).filter { $0.hasPrefix("MiniWattsPro-") }.isEmpty, "Cancelled export must remove temporary files")
        for pdf in [false, true] {
            let duringWrite = Task.detached {
                try ReportGenerator.generate(records, pdf: pdf, lower: 20, upper: 80, single: false,
                            generated: generated, version: "", timezone: "UTC", progress: { _ in
                                withUnsafeCurrentTask { $0?.cancel() }
                            })
            }
            do { _ = try await duringWrite.value; fatalError("Cancellation while writing must be honored") }
            catch is CancellationError { }
        }
        let cancelledStream = Task.detached {
            try await ReportGenerator.generateCSV(selection.map { $0.summary() }, generated: generated,
                        version: "", timezone: "UTC", lower: 20, upper: 80,
                        load: { snapshot in selection.first { $0.id == snapshot.id }! }, progress: { _ in
                            withUnsafeCurrentTask { $0?.cancel() }
                        })
        }
        do { _ = try await cancelledStream.value; fatalError("Streaming export cancellation must be honored") }
        catch is CancellationError { }
        let final = Set(try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path))
        check(final.subtracting(before).filter { $0.hasPrefix("MiniWattsPro-") }.isEmpty, "Partial PDF and CSV files must be removed after cancellation")
        print("PDF pagination, \(chinese ? "Chinese" : "English") localization, CSV consistency, empty selection and cancellation passed")
    }
}
