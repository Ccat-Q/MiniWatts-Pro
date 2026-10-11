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
            var totals = EnergyTotals()
            totals.integratedSeconds = Double(offset)
            totals.batteryMeasuredSeconds = Double(offset)
            totals.batteryWattHours = 8 * Double(offset) / 3600
            if !wireless {
                totals.inputMeasuredSeconds = Double(offset)
                totals.inputWattHours = 10 * Double(offset) / 3600
                totals.pairedInputWattHours = totals.inputWattHours
                totals.pairedBatteryWattHours = totals.batteryWattHours
            }
            s.samples.append(ChargeSample(offset: Double(offset), inputWatts: wireless ? nil : 10, batteryWatts: 8,
                                          percent: min(100, 19 + offset / secondsPerPercent), batteryTemperature: 30,
                                          hottestTemperature: 35, throttled: false, observedSeconds: Double(offset), energyTotals: totals))
        }
        s.end = start.addingTimeInterval(Double(81 * secondsPerPercent))
        s.lastObserved = s.end!
        s.endPercent = 100
        s.peakInputWatts = wireless ? 0 : 10
        s.peakBatteryWatts = 8
        s.peakBatteryTemperature = 30
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
        let day = Date(timeIntervalSince1970: 1_700_000_000)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var recent = ChargeSession(start: day.addingTimeInterval(-6 * 86400), startPercent: 20,
                                   adapterName: nil, adapterRatedWatts: nil, isWireless: false)
        recent.end = day.addingTimeInterval(86400) // A selected session may finish outside the filter.
        let old = ChargeSession(start: day.addingTimeInterval(-8 * 86400), startPercent: 20,
                                adapterName: nil, adapterRatedWatts: nil, isWireless: false)
        let selected = ChargeAnalysis.selectedSessions([recent, old], period: .week, now: day, from: day, to: day, calendar: calendar)
        check(selected.map(\.id) == [recent.id] && selected[0].end == recent.end, "Date filters select whole finished sessions by start time")
        let custom = ChargeAnalysis.selectedSessions([recent], period: .custom, now: day, from: recent.start,
                                                      to: recent.start, calendar: calendar)
        check(custom.count == 1, "Custom dates include the complete local calendar day")
        check(summary.samples.isEmpty && summary.sampleCount == original.samples.count, "Index must not carry full samples")
        check(ChargeAnalysis.duration(summary.steps, from: 20, to: 80) == 7200, "Comparable interval must use full percent boundaries")
        check(ChargeAnalysis.duration(summary.steps, from: 19, to: 80) == nil, "Initial partial percent cannot count")
        check(summary.averageBatteryTemperature == 30, "Time-weighted temperature")
        let comparison = ChargeAnalysis.comparableMetrics(summary, from: 20, to: 80)!
        check(abs(comparison.totals.inputWattHours - 20) < 0.000001 && abs(comparison.batteryWh! - 16) < 0.000001, "Comparison energy is bounded by the selected percentage interval")
        check(abs(comparison.totals.averageInputWatts! - 10) < 0.000001 && abs(comparison.averageBatteryWatts! - 8) < 0.000001, "Comparison means use the corresponding measured duration")
        check(comparison.averageTemperature == 30 && comparison.peakTemperature == 30 && comparison.coverage == 1, "Interval temperature and coverage use the same boundaries")
        let wirelessComparison = ChargeAnalysis.comparableMetrics(session(wireless: true).summary(), from: 20, to: 80)!
        check(wirelessComparison.totals.measuredInputWattHours == nil && wirelessComparison.totals.chargePathEfficiencyPercent == nil, "Wireless interval metrics preserve missing input")
        var gap = original
        gap.samples[24] = ChargeSample(offset: gap.samples[24].offset, inputWatts: nil, batteryWatts: nil,
                                      percent: nil, batteryTemperature: nil, hottestTemperature: nil, throttled: false,
                                      startsNewObservation: true)
        check(ChargeAnalysis.duration(gap.summary().steps, from: 20, to: 80) == nil, "Gaps cannot create full charge intervals")
        var lowCoverage = summary
        lowCoverage.steps = summary.steps.map { ChargeStep(from: $0.from, seconds: $0.seconds, run: $0.run, observedSeconds: $0.seconds * 0.8) }
        check(ChargeAnalysis.comparableSeconds(lowCoverage, from: 20, to: 80) == nil, "Low coverage is not ranked")
        var badTail = summary
        badTail.totals.integratedSeconds = badTail.duration * 0.1
        check(ChargeAnalysis.comparableSeconds(badTail, from: 20, to: 80) == 7200, "Gaps outside the selected interval cannot exclude a complete interval")
        let wireless = session(wireless: true).summary()
        check(wireless.totals.measuredInputWattHours == nil && wireless.totals.chargePathEfficiencyPercent == nil, "Wireless missing input")
        var measuredZero = EnergyTotals()
        measuredZero.inputMeasuredSeconds = 60
        check(measuredZero.measuredInputWattHours == 0, "A measured zero is different from a missing reading")
        measuredZero.pairedInputWattHours = 1
        check(measuredZero.chargePathEfficiencyPercent == 0, "A real zero battery contribution is zero percent")
        var tiny = summary
        tiny.totals.pairedInputWattHours = 1; tiny.totals.pairedBatteryWattHours = 0.1
        var large = summary
        large.totals.pairedInputWattHours = 9; large.totals.pairedBatteryWattHours = 8.1
        check(abs(AnalysisTotals(sessions: [tiny, large]).cellShare! - 82) < 0.001, "Efficiency must weight paired energy")
        let predictor = ChargePredictor()
        let time = Date(timeIntervalSince1970: 20_000)
        predictor.observe(date: time, percent: 50, connected: true, charging: true)
        let histories = [summary, session(secondsPerPercent: 120).summary(), session(secondsPerPercent: 120).summary()]
        check(predictor.estimate(percent: 50, target: 100, connected: true, charging: true, wireless: false,
                                 model: "test", history: histories, now: time).seconds == 6000, "Historical taper segments")
        check(predictor.estimate(percent: 50, target: 100, connected: true, charging: true, wireless: false,
                                 model: "test", history: [summary, summary, summary], now: time).state == .collecting, "Three distinct records are required")
        check(predictor.estimate(percent: 50, target: 100, connected: true, charging: true, wireless: true,
                                 model: "test", history: histories, now: time).state == .collecting, "Never mix wired with wireless")
        check(predictor.estimate(percent: 80, target: 80, connected: true, charging: false, wireless: false,
                                 model: "test", history: [], now: time).state == .reached, "Reached target before hold")
        predictor.reset(interrupted: true)
        check(predictor.estimate(percent: 50, target: 100, connected: true, charging: true, wireless: false,
                                 model: "test", history: histories, now: time).state == .interrupted, "No stale countdown")
        predictor.reset()
        for offset in 0...120 {
            predictor.observe(date: time.addingTimeInterval(Double(offset)), percent: 50 + offset / 60, connected: true, charging: true)
        }
        let trend = predictor.estimate(percent: 52, target: 80, connected: true, charging: true, wireless: false,
                                       model: "test", history: [], now: time.addingTimeInterval(120))
        check(trend.source == .trend && trend.seconds == 1680, "Two percentage changes provide a current trend")
        check(predictor.estimate(percent: 52, target: 90, connected: true, charging: true, wireless: false,
                                 model: "test", history: [], now: time.addingTimeInterval(120)).seconds == 2280, "Changing the target immediately recomputes ETA")
        let taper = histories.map { session in
            var s = session
            s.steps = session.steps.map { ChargeStep(from: $0.from, seconds: $0.from >= 80 ? 240 : 60, run: $0.run,
                                                      observedSeconds: $0.from >= 80 ? 240 : 60) }
            return s
        }
        let hybrid = predictor.estimate(percent: 52, target: 100, connected: true, charging: true, wireless: false,
                                        model: "test", history: taper, now: time.addingTimeInterval(120))
        check(hybrid.source == .hybrid && hybrid.seconds == 6480, "Historical tail segments capture taper beyond the current slope")
        predictor.observe(date: time.addingTimeInterval(131), percent: 52, connected: true, charging: true)
        check(predictor.estimate(percent: 52, target: 80, connected: true, charging: true, wireless: false,
                                 model: "test", history: [], now: time.addingTimeInterval(131)).state == .interrupted, "A gap resets the current trend")
        check(predictor.estimate(percent: nil, target: 80, connected: true, charging: true, wireless: false,
                                 model: "test", history: [], now: time).state == .noReading, "Missing percent remains missing")
        check(predictor.estimate(percent: 52, target: 80, connected: true, charging: false, wireless: false,
                                 model: "test", history: [], now: time).state == .paused, "A paused charge cannot show a countdown")
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
        let damagedID = rebuilt.first!.id
        try Data("broken".utf8).write(to: root.appendingPathComponent(damagedID.uuidString + ".json"))
        try FileManager.default.removeItem(at: root.appendingPathComponent("index.json"))
        let recoveredStore = SessionStore(root: root)
        let recovered = try await recoveredStore.loaded()
        let warning = await recoveredStore.readWarning()
        check(recovered.count == 64 && warning != nil, "A damaged session is quarantined without losing other sessions")
        let preserved = try FileManager.default.contentsOfDirectory(atPath: root.path)
        check(preserved.contains { $0.hasPrefix(damagedID.uuidString + ".corrupt-") }, "The damaged original must remain available")
        let bad = root.appendingPathComponent("not-a-directory")
        try Data().write(to: bad)
        do { _ = try await SessionStore(root: bad).save(original); fatalError("Disk failure must be reported") }
        catch { }
        print("All analytics, CSV and history tests passed")
    }
}
