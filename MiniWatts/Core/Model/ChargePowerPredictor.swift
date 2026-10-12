import Foundation

/// A capacity assumption, never a claim that the remaining energy was measured.
nonisolated struct ChargePowerCapacity: Equatable, Sendable {
    enum Source: Equatable, Sendable { case reportedMaximum, reportedDesign, iPhone17Rating, configured }
    let wattHours: Double
    let source: Source

    static func resolve(model: String, maximumMAh: Int?, designMAh: Int?, voltage: Double?,
                        configuredWh: Double?) -> Self? {
        if let configuredWh, configuredWh.isFinite, (5...40).contains(configuredWh) {
            return Self(wattHours: configuredWh, source: .configured)
        }
        guard let voltage, voltage.isFinite, (2.5...20).contains(voltage) else { return nil }
        let candidates: [(Int?, Source)] = [(maximumMAh, .reportedMaximum), (designMAh, .reportedDesign),
                                            (model == "iPhone18,3" ? 3692 : nil, .iPhone17Rating)]
        for (capacity, source) in candidates {
            guard let capacity, capacity > 0 else { continue }
            let wh = Double(capacity) * voltage / 1000
            if wh.isFinite, (5...100).contains(wh) { return Self(wattHours: wh, source: source) }
        }
        return nil
    }
}

/// Precomputed once when completed records change, rather than scanning history
/// for every sensor tick. Only fully covered, same-device/way segments qualify.
nonisolated struct ChargePowerHistory: Sendable {
    var rates = [Double?](repeating: nil, count: 20)
    var counts = [Int](repeating: 0, count: 20)
    var energyPerPercent = [Double?](repeating: nil, count: 20)

    init() {}

    init(sessions: [ChargeSession], model: String, wireless: Bool) {
        var seen: Set<UUID> = []
        let eligible = sessions.filter {
            !$0.isOpen && $0.deviceModel == model && $0.isWireless == wireless && seen.insert($0.id).inserted
        }
        for bin in 0..<20 {
            let values = eligible.compactMap { ChargeAnalysis.comparableSeconds($0, from: bin * 5, to: bin * 5 + 5) }
            counts[bin] = values.count
            if values.count >= 3 { rates[bin] = ChargeAnalysis.median(values).map { $0 / 5 } }
            let energies = eligible.compactMap { session -> Double? in
                guard let metrics = ChargeAnalysis.comparableMetrics(session, from: bin * 5, to: bin * 5 + 5),
                      metrics.seconds > 0, metrics.totals.batteryMeasuredSeconds / metrics.seconds >= 0.9,
                      metrics.totals.batteryWattHours > 0 else { return nil }
                return metrics.totals.batteryWattHours / 5
            }
            if energies.count >= 3 { energyPerPercent[bin] = ChargeAnalysis.median(energies) }
        }
    }
}

nonisolated struct ChargePowerETA: Equatable, Sendable {
    enum State: Equatable, Sendable { case unplugged, paused, reached, noReading, noPower, noCapacity, collecting, interrupted, estimating }
    enum Source: Equatable, Sendable { case laboratory, history, hybrid }
    var state: State
    var referenceSeconds: Double?
    var correctedSeconds: Double?
    var source: Source?
    var averageWatts: Double?
    var capacity: ChargePowerCapacity?
    var historyCount: Int = 0
    var observationSeconds: Double = 0
    var usesHistoricalEnergy = false
}

nonisolated final class ChargePowerPredictor {
    private struct Sample { let date: Date; let watts: Double }
    private var samples: [Sample] = []
    private var wireless: Bool?
    private var interrupted = false

    func reset(interrupted: Bool = false) {
        samples = []
        wireless = nil
        self.interrupted = interrupted
    }

    func observe(date: Date, watts: Double?, connected: Bool, charging: Bool, wireless: Bool) {
        guard connected, charging, let watts, watts.isFinite, watts > 0.05 else { reset(); return }
        if let last = samples.last {
            let gap = date.timeIntervalSince(last.date)
            if gap == 0 { return }
            if gap < 0 || gap > 10 || self.wireless != wireless { reset() }
        }
        self.wireless = wireless
        samples.append(Sample(date: date, watts: watts))
        samples.removeAll { date.timeIntervalSince($0.date) > 30 }
        interrupted = false
    }

    func estimate(percent: Int?, target: Int, connected: Bool, charging: Bool, model: String,
                  wireless: Bool, capacity: ChargePowerCapacity?, history: ChargePowerHistory,
                  now: Date) -> ChargePowerETA {
        guard connected else { return ChargePowerETA(state: .unplugged) }
        guard let percent, (0...100).contains(percent) else { return ChargePowerETA(state: .noReading) }
        let target = min(max(target, 50), 100)
        if percent >= target { return ChargePowerETA(state: .reached, referenceSeconds: 0) }
        guard charging else { return ChargePowerETA(state: .paused) }
        guard let last = samples.last else { return ChargePowerETA(state: interrupted ? .interrupted : .noPower) }
        guard (0...10).contains(now.timeIntervalSince(last.date)), self.wireless == wireless else {
            return ChargePowerETA(state: .interrupted)
        }
        let duration = last.date.timeIntervalSince(samples[0].date)
        guard samples.count >= 2, duration >= 4 else {
            return ChargePowerETA(state: .collecting, observationSeconds: duration)
        }
        var joules = 0.0, seconds = 0.0
        for (a, b) in zip(samples, samples.dropFirst()) {
            let dt = b.date.timeIntervalSince(a.date)
            joules += (a.watts + b.watts) / 2 * dt
            seconds += dt
        }
        let power = joules / seconds
        guard power.isFinite, power > 0.05 else { return ChargePowerETA(state: .noPower) }
        let anchor = percent / 5
        let historicalEnergy = history.energyPerPercent[anchor]
        let energyPerPercent = historicalEnergy ?? capacity.map { $0.wattHours / 100 }
        guard let energyPerPercent, energyPerPercent.isFinite, energyPerPercent > 0 else {
            return ChargePowerETA(state: .noCapacity, averageWatts: power)
        }
        let currentSecondsPerPercent = energyPerPercent * 3600 / power
        let reference = currentSecondsPerPercent * Double(target - percent)
        guard reference.isFinite, reference > 0 else { return ChargePowerETA(state: .noPower) }
        var result = ChargePowerETA(state: .estimating, referenceSeconds: reference,
                                    averageWatts: power, capacity: capacity, observationSeconds: duration,
                                    usesHistoricalEnergy: historicalEnergy != nil)
        let historyAnchor = history.rates[anchor]
        let laboratoryAnchor = Self.laboratoryRate(percent: percent, model: model, wireless: wireless)
        var corrected = 0.0
        var usesHistory = historyAnchor != nil
        var usesLaboratory = historyAnchor == nil && laboratoryAnchor != nil
        var historyCount = usesHistory ? history.counts[anchor] : Int.max
        var cursor = percent
        while cursor < target {
            let bin = cursor / 5
            let end = min((bin + 1) * 5, target)
            var ratio = 1.0
            if bin != anchor {
                if let base = historyAnchor, let future = history.rates[bin], base > 0 {
                    ratio = max(1, future / base)
                    usesHistory = true
                    historyCount = min(historyCount, min(history.counts[anchor], history.counts[bin]))
                } else if let base = laboratoryAnchor,
                          let future = Self.laboratoryRate(percent: cursor, model: model, wireless: wireless) {
                    ratio = max(1, future / base)
                    usesLaboratory = true
                } else { return result } // Keep the reference; do not fabricate missing tail bins.
            }
            corrected += Double(end - cursor) * currentSecondsPerPercent * ratio
            cursor = end
        }
        if usesHistory || usesLaboratory {
            result.correctedSeconds = corrected
            result.source = usesHistory ? (usesLaboratory ? .hybrid : .history) : .laboratory
            result.historyCount = usesHistory ? historyCount : 0
        }
        return result
    }

    /// A shape prior, scaled to CURRENT CELL power, not the tester's adapter watts.
    /// iPhone 17 wired, 25 °C, Huntkey S140 Pro C1, 2026-01-08:
    /// 20/50/80/90/100% at 7/19/44/59/101 min. 0–20% extrapolates 20–50%.
    /// https://www.chongdiantou.com/archives/1769392865663.html
    /// The laboratory full-charge endpoint can differ from the UI's 100%.
    static func laboratoryRate(percent: Int, model: String, wireless: Bool) -> Double? {
        guard model == "iPhone18,3", !wireless, (0..<100).contains(percent) else { return nil }
        switch percent {
        case ..<50: return (19.0 - 7) * 60 / 30
        case ..<80: return (44.0 - 19) * 60 / 30
        case ..<90: return (59.0 - 44) * 60 / 10
        default: return (101.0 - 59) * 60 / 10
        }
    }
}
