import Foundation

nonisolated struct ChargeSample: Codable, Hashable, Identifiable, Sendable {
    let offset: TimeInterval
    let inputWatts: Double?
    let batteryWatts: Double?
    let percent: Int?
    let batteryTemperature: Double?
    let hottestTemperature: Double?
    let throttled: Bool
    var isCharging: Bool = true
    var startsNewObservation: Bool = false
    /// Cumulative foreground observation time at this sample, independent of rail availability.
    var observedSeconds: TimeInterval = 0
    var id: TimeInterval { offset }
}

/// One fully observed percent transition. Runs separate pauses and missing data.
nonisolated struct ChargeStep: Codable, Hashable, Sendable {
    let from: Int
    let seconds: TimeInterval
    let run: Int
    let observedSeconds: TimeInterval
}

nonisolated struct ChargeSession: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let start: Date
    var end: Date?
    var startPercent: Int?
    var endPercent: Int?
    var totals = EnergyTotals()
    var samples: [ChargeSample] = []
    var peakInputWatts: Double = 0
    var peakBatteryWatts: Double = 0
    var peakBatteryTemperature: Double?
    var adapterName: String?
    var adapterRatedWatts: Double?
    var isWireless: Bool
    var throttledSeconds: TimeInterval = 0
    var pathMilliohms: Double?
    var pathSamples: Int?
    var targetPercent: Int = 100
    var deviceModel: String = ""
    var systemVersion: String = ""
    var lastObserved: Date
    var interrupted = false
    var sampleCount = 0
    var steps: [ChargeStep] = []
    var previewPower: [Double] = []
    var temperatureDegreeSeconds: Double = 0
    var temperatureMeasuredSeconds: Double = 0

    var isOpen: Bool { end == nil }
    var duration: TimeInterval { max(0, (end ?? lastObserved).timeIntervalSince(start)) }
    var gainedPercent: Int? {
        guard let startPercent, let endPercent else { return nil }
        return max(endPercent - startPercent, 0)
    }
    var coverage: Double { duration > 0 ? min(totals.integratedSeconds / duration, 1) : 0 }
    var averageBatteryWatts: Double? {
        totals.batteryMeasuredSeconds > 0 ? totals.batteryWattHours * 3600 / totals.batteryMeasuredSeconds : nil
    }
    var measuredBatteryWattHours: Double? {
        totals.batteryMeasuredSeconds > 0 ? totals.batteryWattHours : nil
    }
    var averageBatteryTemperature: Double? {
        temperatureMeasuredSeconds > 0 ? temperatureDegreeSeconds / temperatureMeasuredSeconds : nil
    }
    var fallbackTitle: LocalizedStringResource { isWireless ? "Wireless charger" : "Unknown adapter" }
    var throttledFraction: Double { duration > 0 ? min(throttledSeconds / duration, 1) : 0 }
    var levelDescription: String { "\(startPercent.map(String.init) ?? "—")% → \(endPercent.map(String.init) ?? "—")%" }

    init(start: Date, startPercent: Int?, adapterName: String?, adapterRatedWatts: Double?, isWireless: Bool) {
        id = UUID()
        self.start = start
        self.startPercent = startPercent
        endPercent = startPercent
        self.adapterName = adapterName
        self.adapterRatedWatts = adapterRatedWatts
        self.isWireless = isWireless
        lastObserved = start
    }

    /// Index representation; full samples stay in the session file.
    func summary() -> ChargeSession {
        var value = self
        if !samples.isEmpty {
            value.sampleCount = samples.count
            value.steps = ChargeAnalysis.steps(samples)
            let powers = samples.compactMap { $0.inputWatts ?? $0.batteryWatts }
            let strideSize = max(1, Int(ceil(Double(powers.count) / 64)))
            value.previewPower = stride(from: 0, to: powers.count, by: strideSize).compactMap {
                powers[$0..<min($0 + strideSize, powers.count)].max()
            }
            value.temperatureDegreeSeconds = 0
            value.temperatureMeasuredSeconds = 0
            for (a, b) in zip(samples, samples.dropFirst()) {
                let dt = b.offset - a.offset
                if !b.startsNewObservation, dt > 0, dt <= 10,
                   let ta = a.batteryTemperature, let tb = b.batteryTemperature {
                    value.temperatureDegreeSeconds += (ta + tb) / 2 * dt
                    value.temperatureMeasuredSeconds += dt
                }
            }
        }
        value.samples = []
        return value
    }
}
