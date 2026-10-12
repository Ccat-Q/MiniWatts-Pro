import Foundation

/// Trapezoidal integration of the live power readings.
///
/// Samples arrive about once a second while the app is in the foreground and stop
/// entirely when it is backgrounded. Rather than extrapolate across those gaps,
/// any interval longer than `maximumInterval` is discarded — the totals then read
/// as "energy measured while watching", which is honest, and `integratedSeconds`
/// records how much of the wall clock that covered.
nonisolated final class EnergyAccumulator {
    private struct Sample {
        let date: Date
        let inputWatts: Double?
        let batteryWatts: Double?
        let batteryAmps: Double?
    }

    /// Longest gap that still counts as continuous measurement.
    private static let maximumInterval: TimeInterval = 10

    private(set) var totals = EnergyTotals()
    private var previous: Sample?

    func reset() {
        totals = EnergyTotals()
        previous = nil
    }

    /// Discard the next interval after suspension without clearing the accumulated energy.
    func breakObservation() { previous = nil }

    func add(_ snapshot: PowerSnapshot) {
        let sample = Sample(date: snapshot.date,
                            inputWatts: snapshot.inputWatts,
                            batteryWatts: snapshot.batteryWatts.map { max($0, 0) },
                            batteryAmps: snapshot.batteryCurrent.map { max($0, 0) })
        defer { previous = sample }
        guard let previous else { return }

        let interval = sample.date.timeIntervalSince(previous.date)
        guard interval > 0, interval <= Self.maximumInterval else { return }

        let hours = interval / 3600
        if let previousInput = previous.inputWatts, let input = sample.inputWatts {
            totals.inputWattHours += (previousInput + input) / 2 * hours
            totals.inputMeasuredSeconds += interval
        }
        if let previousBattery = previous.batteryWatts, let battery = sample.batteryWatts {
            totals.batteryWattHours += (previousBattery + battery) / 2 * hours
            totals.batteryMeasuredSeconds += interval
        }
        if let previousAmps = previous.batteryAmps, let amps = sample.batteryAmps {
            totals.batteryMilliAmpHours += (previousAmps + amps) / 2 * hours * 1000
            totals.batteryCurrentMeasuredSeconds += interval
        }
        if let previousInput = previous.inputWatts, let input = sample.inputWatts,
           let previousBattery = previous.batteryWatts, let battery = sample.batteryWatts {
            totals.pairedInputWattHours += (previousInput + input) / 2 * hours
            totals.pairedBatteryWattHours += (previousBattery + battery) / 2 * hours
        }
        // Every watched interval, whichever rails answered in it. History sets
        // this against the session's length to say how much of the charge the app
        // was in front for; what each rail covered is in the fields above.
        totals.integratedSeconds += interval
    }
}
