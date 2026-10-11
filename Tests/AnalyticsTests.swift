import Foundation

@main struct AnalyticsTests {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }
    static func session(wireless: Bool = false, secondsPerPercent: Int = 60) -> ChargeSession {
        let start = Date(timeIntervalSince1970: 1_000)
        var s = ChargeSession(start: start, startPercent: 19, adapterName: "Adapter, \"test\"\nline", adapterRatedWatts: 30, isWireless: wireless)
        s.deviceModel = "test"
        for offset in stride(from: 0, through: 81 * secondsPerPercent, by: 5) {
            s.samples.append(ChargeSample(offset: Double(offset), inputWatts: wireless ? nil : 10, batteryWatts: 8,
                                          percent: min(100, 19 + offset / secondsPerPercent), batteryTemperature: 30,
                                          hottestTemperature: 35, throttled: false))
        }
        s.end = start.addingTimeInterval(Double(81 * secondsPerPercent))
        s.lastObserved = s.end!
        s.totals.integratedSeconds = s.duration
        s.totals.batteryMeasuredSeconds = s.duration
        s.totals.batteryWattHours = 8 * s.duration / 3600
        if !wireless {
            s.totals.inputMeasuredSeconds = s.duration
            s.totals.inputWattHours = 10 * s.duration / 3600
            s.totals.pairedInputWattHours = s.totals.inputWattHours
            s.totals.pairedBatteryWattHours = s.totals.batteryWattHours
        }
        return s
    }
    static func main() async throws {
        let original = session(secondsPerPercent: 120)
        let summary = original.summary()
        check(summary.samples.isEmpty && summary.sampleCount == original.samples.count, "Index must not carry full samples")
        check(ChargeAnalysis.duration(summary.steps, from: 20, to: 80) == 7200, "Comparable interval must use full percent boundaries")
        check(ChargeAnalysis.duration(summary.steps, from: 19, to: 80) == nil, "Initial partial percent cannot count")
        check(summary.averageBatteryTemperature == 30, "Time-weighted temperature")
        var gap = original
        gap.samples[24] = ChargeSample(offset: gap.samples[24].offset, inputWatts: nil, batteryWatts: nil,
                                      percent: nil, batteryTemperature: nil, hottestTemperature: nil, throttled: false,
                                      startsNewObservation: true)
        check(ChargeAnalysis.duration(gap.summary().steps, from: 20, to: 80) == nil, "Gaps cannot create full charge intervals")
        var lowCoverage = summary
        lowCoverage.totals.integratedSeconds = lowCoverage.duration * 0.8
        check(ChargeAnalysis.comparableSeconds(lowCoverage, from: 20, to: 80) == nil, "Low coverage is not ranked")
        let wireless = session(wireless: true).summary()
        check(wireless.totals.measuredInputWattHours == nil && wireless.totals.chargePathEfficiencyPercent == nil, "Wireless missing input")
        var tiny = summary
        tiny.totals.pairedInputWattHours = 1; tiny.totals.pairedBatteryWattHours = 0.1
        var large = summary
        large.totals.pairedInputWattHours = 9; large.totals.pairedBatteryWattHours = 8.1
        check(abs(AnalysisTotals(sessions: [tiny, large]).cellShare! - 82) < 0.001, "Efficiency must weight paired energy")
        let predictor = ChargePredictor()
        let time = Date(timeIntervalSince1970: 20_000)
        predictor.observe(date: time, percent: 50, connected: true, charging: true)
        let histories = [summary, summary, summary]
        check(predictor.estimate(percent: 50, target: 100, connected: true, charging: true, wireless: false,
                                 model: "test", history: histories, now: time).seconds == 6000, "Historical taper segments")
        check(predictor.estimate(percent: 50, target: 100, connected: true, charging: true, wireless: true,
                                 model: "test", history: histories, now: time).state == .collecting, "Never mix wired with wireless")
        check(predictor.estimate(percent: 80, target: 80, connected: true, charging: false, wireless: false,
                                 model: "test", history: [], now: time).state == .reached, "Reached target before hold")
        predictor.reset(interrupted: true)
        check(predictor.estimate(percent: 50, target: 100, connected: true, charging: true, wireless: false,
                                 model: "test", history: histories, now: time).state == .interrupted, "No stale countdown")
        check(ReportCSV.row(["a,b", "x\"y", "", "line\nbreak"]) == "\"a,b\",\"x\"\"y\",\"\",\"line\nbreak\"\r\n", "CSV escaping")
        check(ReportCSV.number(nil).isEmpty && ReportCSV.number(.nan).isEmpty, "CSV preserves missing values")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(root: root)
        var ids = Set<UUID>()
        for _ in 0..<65 {
            var s = session(secondsPerPercent: 5)
            if ids.isEmpty { s = original }
            ids.insert(s.id)
            _ = try await store.save(s)
        }
        let loaded = try await store.loaded()
        check(loaded.count == 65, "No 60-session limit")
        let detail = try await store.detail(original.id)
        check(detail.samples.count == original.samples.count, "Complete curves remain on disk")
        var open = session(); open.end = nil
        _ = try await store.save(open)
        _ = try await store.delete([open.id])
        _ = try await store.detail(open.id)
        let restored = try await SessionStore(root: root).loaded()
        check(restored.count == 66 && restored.first(where: { $0.id == open.id })?.interrupted == true, "Crash recovery and protection of open sessions")
        _ = try await store.delete([original.id])
        _ = try await store.save(original)
        let afterDelete = try await store.loaded()
        check(afterDelete.count == 64, "Deleted sessions cannot be resurrected by a queued save")
        try Data("broken".utf8).write(to: root.appendingPathComponent("index.json"))
        let rebuilt = try await SessionStore(root: root).loaded()
        check(rebuilt.count == 65, "Index rebuild from independent session files")
        let bad = root.appendingPathComponent("not-a-directory")
        try Data().write(to: bad)
        do { _ = try await SessionStore(root: bad).save(original); fatalError("Disk failure must be reported") }
        catch { }
        print("All analytics, CSV and history tests passed")
    }
}
