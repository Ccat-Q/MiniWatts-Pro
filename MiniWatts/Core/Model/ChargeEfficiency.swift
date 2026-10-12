import Foundation

/// The measured share reaching the cell, including the effect of phone load.
/// It is not the isolated efficiency of the adapter or charging IC.
nonisolated enum ChargeEfficiency {
    /// A measured zero or battery discharge contributes no charging power.
    /// Very small input readings cannot provide a useful power ratio.
    static func instantaneous(inputWatts: Double?, batteryWatts: Double?) -> Double? {
        guard let batteryWatts, batteryWatts.isFinite else { return nil }
        return percent(input: inputWatts, battery: max(batteryWatts, 0), minimumInput: 0.5)
    }

    /// Both energies must cover the same intervals. Callers pass paired totals,
    /// rather than independently measured whole-session energies.
    static func cumulative(inputWattHours: Double, batteryWattHours: Double) -> Double? {
        percent(input: inputWattHours, battery: batteryWattHours, minimumInput: 0.001)
    }

    private static func percent(input: Double?, battery: Double, minimumInput: Double) -> Double? {
        guard let input, input.isFinite, input > minimumInput,
              battery.isFinite, battery >= 0 else { return nil }
        return min(battery / input, 1) * 100
    }
}
