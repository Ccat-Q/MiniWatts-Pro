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
        let activityTime = Date(timeIntervalSince1970: 5_000)
        var activityGate = LiveActivityUpdateGate()
        check(activityGate.shouldSend(at: activityTime, changed: false), "The first activity state is submitted")
        check(!activityGate.shouldSend(at: activityTime.addingTimeInterval(0.5), changed: true), "Rapid sensor updates are coalesced")
        check(activityGate.shouldSend(at: activityTime.addingTimeInterval(1), changed: true), "A changed displayed reading is submitted on the next one-second tick")
        check(!activityGate.shouldSend(at: activityTime.addingTimeInterval(20), changed: false), "Unchanged readings do not waste the local update budget")
        check(activityGate.shouldSend(at: activityTime.addingTimeInterval(21), changed: false), "A heartbeat keeps the stale date current")
        check(activityGate.shouldSend(at: activityTime.addingTimeInterval(21), changed: true, force: true), "Background pause bypasses the interval gate")
        check(activityGate.shouldSend(at: activityTime.addingTimeInterval(21.1), changed: true, force: true), "Foreground resume bypasses the interval gate")
        check(activityGate.shouldSend(at: activityTime, changed: false), "Clock changes cannot suppress updates indefinitely")
        activityGate.reset()
        check(activityGate.shouldSend(at: activityTime, changed: false), "A new activity starts with a fresh update gate")
        check(ChargeEfficiency.instantaneous(inputWatts: 20, batteryWatts: 15) == 75, "Instantaneous efficiency uses measured power")
        check(ChargeEfficiency.instantaneous(inputWatts: 20, batteryWatts: 0) == 0, "Measured zero cell power is zero efficiency")
        check(ChargeEfficiency.instantaneous(inputWatts: 20, batteryWatts: -2) == 0, "Battery discharge has no incoming charging contribution")
        check(ChargeEfficiency.instantaneous(inputWatts: nil, batteryWatts: 15) == nil, "Missing wireless input cannot use the adapter rating")
        check(ChargeEfficiency.instantaneous(inputWatts: 20, batteryWatts: nil) == nil, "Missing cell power is not a zero")
        check(ChargeEfficiency.instantaneous(inputWatts: 0.5, batteryWatts: 0.1) == nil, "Tiny input cannot supply a reliable ratio")
        check(ChargeEfficiency.instantaneous(inputWatts: 0, batteryWatts: 0) == nil, "Zero input cannot supply a ratio")
        check(ChargeEfficiency.instantaneous(inputWatts: .nan, batteryWatts: 1) == nil, "NaN input is unavailable")
        check(ChargeEfficiency.instantaneous(inputWatts: .infinity, batteryWatts: 1) == nil, "Infinite input is unavailable")
        check(ChargeEfficiency.instantaneous(inputWatts: 10, batteryWatts: .nan) == nil, "NaN cell power is unavailable")
        check(ChargeEfficiency.instantaneous(inputWatts: 10, batteryWatts: .infinity) == nil, "Infinite cell power is unavailable")
        check(ChargeEfficiency.instantaneous(inputWatts: 10, batteryWatts: 12) == 100, "Preserve the bounded display for mismatched rail readings")
        check(ChargeEfficiency.cumulative(inputWattHours: 10, batteryWattHours: 8) == 80, "Cumulative efficiency uses energy")
        check(ChargeEfficiency.cumulative(inputWattHours: 0.001, batteryWattHours: 0) == nil, "Wait for enough paired energy")
        check(ChargeEfficiency.cumulative(inputWattHours: 10, batteryWattHours: -1) == nil, "Negative accumulated energy is invalid")
        var unmatchedTotals = EnergyTotals()
        unmatchedTotals.inputWattHours = 10
        unmatchedTotals.batteryWattHours = 8
        unmatchedTotals.pairedInputWattHours = 2
        unmatchedTotals.pairedBatteryWattHours = 1
        check(unmatchedTotals.chargePathEfficiencyPercent == 50, "Different observation durations must use paired energy, not whole-session totals")
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
        let coldStart = predictor.estimate(percent: 50, target: 100, connected: true, charging: true, wireless: false,
                                            model: "test", history: [], now: time)
        check(coldStart.state == .collecting && coldStart.observedIncreases == 0, "A new session explains the missing trend")
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
        for offset in 0...119 {
            predictor.observe(date: time.addingTimeInterval(Double(offset)), percent: 50 + offset / 60, connected: true, charging: true)
        }
        let partialTrend = predictor.estimate(percent: 51, target: 80, connected: true, charging: true, wireless: false,
                                               model: "test", history: [], now: time.addingTimeInterval(119))
        check(partialTrend.state == .collecting && partialTrend.observedIncreases == 1 && partialTrend.observationSeconds == 119,
              "One level increase reports progress without inventing a countdown")
        predictor.observe(date: time.addingTimeInterval(120), percent: 52, connected: true, charging: true)
        let trend = predictor.estimate(percent: 52, target: 80, connected: true, charging: true, wireless: false,
                                       model: "test", history: [], now: time.addingTimeInterval(120))
        check(trend.source == .trend && trend.seconds == 1680, "Two percentage changes provide a current trend")
        for target in 50...100 {
            let result = predictor.estimate(percent: 52, target: target, connected: true, charging: true,
                                            wireless: false, model: "test", history: [], now: time.addingTimeInterval(120))
            check(target <= 52 ? result.state == .reached : result.seconds == Double(target - 52) * 60,
                  "Every selectable prediction target must return a valid state")
        }
        check(predictor.estimate(percent: 101, target: 100, connected: true, charging: true, wireless: false,
                                 model: "test", history: [], now: time.addingTimeInterval(120)).state == .noReading, "Invalid percentages are not usable readings")
        check(predictor.estimate(percent: 52, target: 101, connected: true, charging: true, wireless: false,
                                 model: "test", history: [], now: time.addingTimeInterval(120)).seconds == 2880, "An out-of-range target is bounded at full charge")
        check(predictor.estimate(percent: 52, target: 80, connected: true, charging: true, wireless: false,
                                 model: "test", history: [], now: time.addingTimeInterval(119)).state == .interrupted, "A future observation cannot produce a current countdown")
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
                                 model: "test", history: [], now: time.addingTimeInterval(131)).state == .collecting, "A fresh sample after a gap resumes collection, without reusing the old trend")
        check(predictor.estimate(percent: nil, target: 80, connected: true, charging: true, wireless: false,
                                 model: "test", history: [], now: time).state == .noReading, "Missing percent remains missing")
        check(predictor.estimate(percent: 52, target: 80, connected: true, charging: false, wireless: false,
                                 model: "test", history: [], now: time).state == .paused, "A paused charge cannot show a countdown")
        predictor.reset()
        for offset in 0...120 {
            predictor.observe(date: time.addingTimeInterval(Double(offset)), percent: 50 + offset / 60,
                              connected: true, charging: true)
        }
        predictor.observe(date: time.addingTimeInterval(121), percent: 54, connected: true, charging: true)
        let adjusted = predictor.estimate(percent: 54, target: 80, connected: true, charging: true,
                                         wireless: false, model: "test", history: [], now: time.addingTimeInterval(121))
        check(adjusted.state == .collecting && adjusted.levelWasAdjusted && adjusted.seconds == nil,
              "A level jump rebuilds the slope, not the electrical observation")
        predictor.observe(date: time.addingTimeInterval(122), percent: 53, connected: true, charging: true)
        check(!predictor.interrupted, "A downward gauge correction is not a sampling gap")
        for offset in 123...241 {
            predictor.observe(date: time.addingTimeInterval(Double(offset)), percent: 53 + (offset - 122) / 60,
                              connected: true, charging: true)
        }
        predictor.observe(date: time.addingTimeInterval(242), percent: 55, connected: true, charging: true)
        check(predictor.estimate(percent: 55, target: 80, connected: true, charging: true, wireless: false,
                                 model: "test", history: [], now: time.addingTimeInterval(242)).seconds == 1500,
              "The trend recovers from new complete level intervals after adjustment")
        predictor.observe(date: time.addingTimeInterval(242), percent: 55, connected: true, charging: true)
        check(!predictor.interrupted, "An identical duplicate tick cannot interrupt observation")
        predictor.reset(interrupted: true)
        predictor.observe(date: time, percent: 50, connected: true, charging: true)
        check(predictor.estimate(percent: 50, target: 80, connected: true, charging: true, wireless: false,
                                 model: "test", history: [], now: time).state == .collecting,
              "Foreground recovery does not wait for a percentage rise to clear interruption")

        let rated = ChargePowerCapacity.resolve(model: "iPhone18,3", maximumMAh: nil, designMAh: nil,
                                                voltage: 4, configuredWh: nil)
        check(rated?.source == .iPhone17Rating && abs(rated!.wattHours - 14.768) < 0.00001,
              "iPhone 17 uses verified mAh with measured voltage, not an unconfirmed default")
        check(ChargePowerCapacity.resolve(model: "unknown", maximumMAh: nil, designMAh: nil,
                                          voltage: 4, configuredWh: nil) == nil, "Unknown capacity stays unavailable")
        check(ChargePowerCapacity.resolve(model: "iPhone18,3", maximumMAh: nil, designMAh: nil,
                                          voltage: nil, configuredWh: nil) == nil, "No fabricated nominal voltage")
        check(ChargePowerCapacity.resolve(model: "unknown", maximumMAh: 3000, designMAh: 4000,
                                          voltage: 4, configuredWh: nil)?.source == .reportedMaximum,
              "Reported full-charge capacity precedes design capacity")
        check(ChargePowerCapacity.resolve(model: "iPhone18,3", maximumMAh: 3000, designMAh: nil,
                                          voltage: nil, configuredWh: 20)?.source == .configured,
              "An explicitly selected energy works without a reported voltage")
        check(ChargePowerCapacity.resolve(model: "unknown", maximumMAh: nil, designMAh: nil,
                                          voltage: .infinity, configuredWh: .nan) == nil,
              "Nonfinite capacity inputs cannot create an energy assumption")
        let powerPredictor = ChargePowerPredictor()
        func powerResult(_ percent: Int = 70, _ target: Int = 100, model: String = "iPhone18,3",
                         wireless: Bool = false, history: ChargePowerHistory = ChargePowerHistory(),
                         energy: ChargePowerCapacity? = ChargePowerCapacity(wattHours: 20, source: .configured),
                         now: Date? = nil) -> ChargePowerETA {
            powerPredictor.estimate(percent: percent, target: target, connected: true, charging: true,
                                    model: model, wireless: wireless, capacity: energy, history: history,
                                    now: now ?? time.addingTimeInterval(4))
        }
        for offset in 0...4 {
            powerPredictor.observe(date: time.addingTimeInterval(Double(offset)), watts: 10,
                                   connected: true, charging: true, wireless: false)
        }
        let powerForecast = powerResult()
        check(powerForecast.referenceSeconds == 2160 && powerForecast.averageWatts == 10,
              "Cell power predicts without any charge-level rise")
        check(powerForecast.source == .laboratory && abs(powerForecast.correctedSeconds! - 5644.8) < 0.001,
              "The sourced laboratory shape includes slower 80–90 and 90–100 tails")
        check(powerResult(70, 80).referenceSeconds == 720, "Target changes recompute power-based remaining charge")
        check(abs(powerResult(80).correctedSeconds! - 2736) < 0.001,
              "At 80 percent the forecast includes the still slower final ten percent")
        check(powerResult(72).referenceSeconds == 2016, "A level jump updates remaining charge without resetting power")
        check(powerResult(model: "unknown").correctedSeconds == nil, "A prior cannot leak to another model")
        check(powerResult(energy: nil).state == .noCapacity, "Missing capacity cannot become a fabricated forecast")
        check(powerResult(now: time.addingTimeInterval(15)).state == .interrupted, "Stale power stops forecasting")
        check(powerResult(now: time.addingTimeInterval(3)).state == .interrupted, "Future power is not current")
        let local = ChargePowerHistory(sessions: taper, model: "test", wireless: false)
        let locallyCorrected = powerResult(model: "test", history: local)
        check(locallyCorrected.source == .history && locallyCorrected.historyCount == 3
              && locallyCorrected.correctedSeconds == 6480, "Local three-record segments override generic taper assumptions")
        let partialHistory = ChargePowerHistory(sessions: Array(taper.prefix(2)), model: "test", wireless: false)
        check(powerResult(model: "test", history: partialHistory).correctedSeconds == nil, "Two records are insufficient for history correction")
        let measuredHistory = ChargePowerHistory(sessions: histories, model: "test", wireless: false)
        let calibrated = powerResult(model: "test", history: measuredHistory, energy: nil)
        check(calibrated.state == .estimating && calibrated.usesHistoricalEnergy
              && abs(calibrated.referenceSeconds! - 1440) < 0.001,
              "Measured local energy can calibrate power forecasts without a guessed battery capacity")
        check(ChargePowerHistory(sessions: [taper[0], taper[0], taper[0]], model: "test", wireless: false).rates[16] == nil,
              "Duplicated history IDs cannot qualify a segment")
        check(ChargePowerHistory(sessions: histories, model: "other", wireless: false).energyPerPercent[14] == nil
              && ChargePowerHistory(sessions: histories, model: "test", wireless: true).rates[14] == nil,
              "Local energy and slowdown profiles cannot cross device or charging-way boundaries")
        powerPredictor.observe(date: time.addingTimeInterval(5), watts: nil, connected: true, charging: true, wireless: false)
        check(powerResult(now: time.addingTimeInterval(5)).state == .noPower, "Missing cell power clears older watts")
        powerPredictor.observe(date: time.addingTimeInterval(6), watts: -1, connected: true, charging: true, wireless: false)
        check(powerResult(now: time.addingTimeInterval(6)).state == .noPower, "Net discharge cannot predict charging")
        for watts in [0.0, Double.nan, Double.infinity] {
            powerPredictor.observe(date: time.addingTimeInterval(6), watts: watts, connected: true, charging: true, wireless: false)
            check(powerResult(now: time.addingTimeInterval(6)).state == .noPower, "Invalid electrical readings remain unavailable")
        }
        for offset in 7...11 {
            powerPredictor.observe(date: time.addingTimeInterval(Double(offset)), watts: 5,
                                   connected: true, charging: true, wireless: true)
        }
        check(powerResult(wireless: true, now: time.addingTimeInterval(11)).correctedSeconds == nil,
              "A wired laboratory curve cannot be used for wireless charging")
        powerPredictor.reset()
        powerPredictor.observe(date: time, watts: 10, connected: true, charging: true, wireless: false)
        powerPredictor.observe(date: time.addingTimeInterval(4), watts: 6, connected: true, charging: true, wireless: false)
        check(powerResult().averageWatts == 8, "Slow but continuous samples still form a time-weighted forecast")
        powerPredictor.observe(date: time.addingTimeInterval(15), watts: 10, connected: true, charging: true, wireless: false)
        check(powerResult(now: time.addingTimeInterval(15)).state == .collecting, "A genuine power gap rebuilds a fresh window")
        check(powerPredictor.estimate(percent: 70, target: 100, connected: true, charging: false, model: "test", wireless: false,
                                     capacity: nil, history: ChargePowerHistory(), now: time).state == .paused,
              "System charging holds cannot be shown as an effective countdown")
        check(powerPredictor.estimate(percent: 90, target: 80, connected: true, charging: false, model: "test", wireless: false,
                                     capacity: nil, history: ChargePowerHistory(), now: time).state == .reached, "Reached targets need no capacity")
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
