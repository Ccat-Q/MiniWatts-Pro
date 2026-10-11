import Foundation

nonisolated enum ChargeAnalysis {
    static func steps(_ samples: [ChargeSample]) -> [ChargeStep] {
        var result: [ChargeStep] = []
        var previous: ChargeSample?
        var boundary: (percent: Int, offset: Double, observedSeconds: Double)?
        var run = 0
        for sample in samples {
            defer { previous = sample }
            guard let percent = sample.percent, (0...100).contains(percent), let prior = previous,
                  let priorPercent = prior.percent else { boundary = nil; run += 1; continue }
            let dt = sample.offset - prior.offset
            guard !sample.startsNewObservation, dt > 0, dt <= 10, prior.isCharging,
                  percent >= priorPercent, percent - priorPercent <= 1 else {
                boundary = nil; run += 1; continue
            }
            if percent > priorPercent {
                if let start = boundary, start.percent == priorPercent, sample.offset > start.offset {
                    result.append(ChargeStep(from: priorPercent, seconds: sample.offset - start.offset, run: run,
                                             observedSeconds: max(0, sample.observedSeconds - start.observedSeconds)))
                }
                boundary = (percent, sample.offset, sample.observedSeconds)
            }
            if !sample.isCharging { boundary = nil; run += 1 }
        }
        return result
    }

    private static func interval(_ steps: [ChargeStep], from lower: Int, to upper: Int) -> ArraySlice<ChargeStep>? {
        guard lower >= 0, upper <= 100, upper > lower else { return nil }
        for index in steps.indices where steps[index].from == lower {
            guard index + upper - lower <= steps.count else { continue }
            let slice = steps[index..<(index + upper - lower)]
            if slice.enumerated().allSatisfy({ $0.element.from == lower + $0.offset && $0.element.run == steps[index].run }) {
                return slice
            }
        }
        return nil
    }

    static func duration(_ steps: [ChargeStep], from lower: Int, to upper: Int) -> Double? {
        interval(steps, from: lower, to: upper)?.reduce(0) { $0 + $1.seconds }
    }

    static func comparableSeconds(_ session: ChargeSession, from: Int, to: Int) -> Double? {
        guard !session.isOpen, let steps = interval(session.steps, from: from, to: to) else { return nil }
        let seconds = steps.reduce(0) { $0 + $1.seconds }
        let observed = steps.reduce(0) { $0 + $1.observedSeconds }
        guard seconds > 0, observed / seconds >= 0.9 else { return nil }
        return seconds
    }

    static func median(_ values: [Double]) -> Double? {
        let sorted = values.filter { $0.isFinite && $0 > 0 }.sorted()
        guard !sorted.isEmpty else { return nil }
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }
}

nonisolated struct AnalysisTotals: Sendable {
    let sessions: [ChargeSession]
    var inputWh: Double? {
        let measured = sessions.compactMap { $0.totals.measuredInputWattHours }
        return measured.isEmpty ? nil : measured.reduce(0, +)
    }
    var batteryWh: Double? {
        let measured = sessions.compactMap(\.measuredBatteryWattHours)
        return measured.isEmpty ? nil : measured.reduce(0, +)
    }
    var cellShare: Double? {
        let input = sessions.reduce(0) { $0 + $1.totals.pairedInputWattHours }
        let battery = sessions.reduce(0) { $0 + $1.totals.pairedBatteryWattHours }
        return input > 0.001 ? min(battery / input, 1) * 100 : nil
    }
    var loadAndLossWh: Double? {
        let input = sessions.reduce(0) { $0 + $1.totals.pairedInputWattHours }
        let battery = sessions.reduce(0) { $0 + $1.totals.pairedBatteryWattHours }
        return input > 0.001 ? max(input - battery, 0) : nil
    }
    var averageInputWatts: Double? {
        let seconds = sessions.reduce(0) { $0 + $1.totals.inputMeasuredSeconds }
        return seconds > 0 ? sessions.reduce(0) { $0 + $1.totals.inputWattHours } * 3600 / seconds : nil
    }
    var averageBatteryWatts: Double? {
        let seconds = sessions.reduce(0) { $0 + $1.totals.batteryMeasuredSeconds }
        return seconds > 0 ? sessions.reduce(0) { $0 + $1.totals.batteryWattHours } * 3600 / seconds : nil
    }
    var averageTemperature: Double? {
        let seconds = sessions.reduce(0) { $0 + $1.temperatureMeasuredSeconds }
        return seconds > 0 ? sessions.reduce(0) { $0 + $1.temperatureDegreeSeconds } / seconds : nil
    }
    var coverage: Double {
        let duration = sessions.reduce(0) { $0 + $1.duration }
        return duration > 0 ? min(sessions.reduce(0) { $0 + $1.totals.integratedSeconds } / duration, 1) : 0
    }
}

nonisolated struct ChargeETA: Equatable, Sendable {
    enum State: String, Sendable { case unplugged, paused, noReading, interrupted, collecting, reached, estimating }
    enum Source: String, Sendable { case trend, history, hybrid }
    var state: State
    var seconds: Double?
    var source: Source?
    var historyCount: Int = 0
}

nonisolated final class ChargePredictor {
    private var previous: (date: Date, percent: Int)?
    private var changes: [(date: Date, percent: Int)] = []
    private(set) var interrupted = false

    func reset(interrupted: Bool = false) {
        previous = nil
        changes = []
        self.interrupted = interrupted
    }

    func observe(date: Date, percent: Int?, connected: Bool, charging: Bool) {
        guard connected, charging, let percent, (0...100).contains(percent) else { reset(); return }
        if let last = previous {
            let dt = date.timeIntervalSince(last.date)
            if dt <= 0 || dt > 10 || percent < last.percent || percent - last.percent > 1 {
                reset(interrupted: true)
            } else if percent > last.percent {
                changes.append((date, percent))
                if changes.count > 7 { changes.removeFirst() }
                interrupted = false
            }
        }
        previous = (date, percent)
    }

    func estimate(percent: Int?, target: Int, connected: Bool, charging: Bool,
                  wireless: Bool, model: String, history: [ChargeSession], now: Date) -> ChargeETA {
        guard connected else { return ChargeETA(state: .unplugged) }
        guard let percent else { return ChargeETA(state: .noReading) }
        if percent >= target { return ChargeETA(state: .reached, seconds: 0) }
        guard charging else { return ChargeETA(state: .paused) }
        guard let last = previous, now.timeIntervalSince(last.date) <= 10, !interrupted else {
            return ChargeETA(state: .interrupted)
        }
        var rate: Double?
        if changes.count >= 2, let first = changes.first, let last = changes.last, last.percent > first.percent {
            rate = last.date.timeIntervalSince(first.date) / Double(last.percent - first.percent)
        }
        var seen: Set<UUID> = []
        let eligible = history.filter { !$0.isOpen && $0.isWireless == wireless && $0.deviceModel == model && seen.insert($0.id).inserted }
        var seconds = 0.0, historical = false, trend = false, historyCount = Int.max
        var cursor = percent
        while cursor < target {
            let lower = cursor / 5 * 5
            let upper = min(lower + 5, target)
            let values = eligible.compactMap { ChargeAnalysis.comparableSeconds($0, from: lower, to: lower + 5) }
            // Current slope takes priority for the present segment; future segments capture taper.
            if cursor == percent, let rate {
                seconds += Double(upper - cursor) * rate; trend = true
            } else if values.count >= 3, let median = ChargeAnalysis.median(values) {
                seconds += Double(upper - cursor) / 5 * median
                historical = true; historyCount = min(historyCount, values.count)
            } else if let rate {
                seconds += Double(upper - cursor) * rate; trend = true
            } else { return ChargeETA(state: .collecting) }
            cursor = upper
        }
        guard seconds.isFinite, seconds > 0 else { return ChargeETA(state: .collecting) }
        return ChargeETA(state: .estimating, seconds: seconds,
                         source: historical ? (trend ? .hybrid : .history) : .trend,
                         historyCount: historical ? historyCount : 0)
    }
}
