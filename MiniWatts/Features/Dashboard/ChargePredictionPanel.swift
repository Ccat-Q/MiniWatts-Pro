import SwiftUI

struct ChargePredictionPanel: View {
    @Environment(PowerMonitor.self) private var monitor
    var body: some View {
        Panel("Charge prediction", systemImage: "clock.badge.checkmark") {
            VStack(alignment: .leading, spacing: 12) {
                Stepper("Target \(monitor.chargeTarget)%", value: Binding(get: { monitor.chargeTarget }, set: { monitor.chargeTarget = $0 }), in: 50...100)
                    .accessibilityIdentifier("prediction.target")
                    .accessibilityValue(Text(verbatim: "\(monitor.chargeTarget)%"))
                HStack {
                    ForEach([80, 90, 100], id: \.self) { target in
                        Button { monitor.chargeTarget = target } label: { Text(verbatim: "\(target)%") }
                            .buttonStyle(.bordered).tint(monitor.chargeTarget == target ? .mwAccent : .mwMuted)
                            .accessibilityIdentifier("prediction.target.\(target)")
                    }
                }
                PowerPredictionReadout()
                Divider()
                PercentagePredictionReadout()
                Text("An estimate to your target, not a system charging limit or guaranteed finish time.")
                    .font(.caption).foregroundStyle(Color.mwMuted)
            }
        }
    }
}

private struct PercentagePredictionReadout: View {
    @Environment(PowerMonitor.self) private var monitor
    private var eta: ChargeETA { monitor.chargeETA }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Charge-level trend").font(.subheadline.weight(.semibold))
                .accessibilityIdentifier("prediction.trend.heading")
            if let seconds = eta.seconds, eta.state == .estimating {
                Text(verbatim: "≈ " + Formatting.duration(seconds))
                    .mwReadout(size: 28, animatedValue: Formatting.duration(seconds))
                switch eta.source {
                case .history: Text("Historical segments; \(eta.historyCount) comparable records per segment.")
                case .hybrid: Text("Recent trend + historical segments; some portions may be extrapolated.")
                default: Text("Recent trend only — rough estimate; charging may slow near full.")
                }
            } else { Text(status).font(.headline) }
            if eta.state == .collecting {
                if eta.levelWasAdjusted {
                    Text("Battery level adjusted — rebuilding the trend, sampling continues.")
                        .font(.caption).foregroundStyle(Color.mwMuted)
                }
                Text("Observed \(eta.observedIncreases) of 2 charge-level increases").font(.subheadline)
                Text("Trend observation: \(Formatting.duration(eta.observationSeconds))")
                    .font(.caption).foregroundStyle(Color.mwMuted)
                Text("Two continuous level rises establish the trend. Level corrections rebuild this model; fresh samples resume collection after background gaps.")
                    .font(.caption).foregroundStyle(Color.mwMuted)
            }
        }
    }
    private var status: LocalizedStringResource {
        switch eta.state {
        case .unplugged: "Connect a charger"
        case .paused: "Charging paused"
        case .noReading: "No charge level reading"
        case .interrupted: "Observation interrupted — waiting for fresh readings"
        case .collecting: "Collecting charge data…"
        case .reached: "Target reached"
        case .estimating: "Estimating…"
        }
    }
}

private struct PowerPredictionReadout: View {
    @Environment(PowerMonitor.self) private var monitor
    private var eta: ChargePowerETA { monitor.powerChargeETA }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Power-based forecast").font(.subheadline.weight(.semibold))
                .accessibilityIdentifier("prediction.power.heading")
            if let seconds = eta.referenceSeconds, eta.state == .estimating {
                Text("At current cell power").font(.caption).foregroundStyle(Color.mwMuted)
                readout(seconds).accessibilityIdentifier("prediction.power.reference")
                if let corrected = eta.correctedSeconds {
                    Text("With charging slowdown").font(.caption).foregroundStyle(Color.mwMuted)
                    readout(corrected).accessibilityIdentifier("prediction.power.corrected")
                    switch eta.source {
                    case .history: Text("Local charging profile; \(eta.historyCount) comparable records per segment.")
                    case .hybrid: Text("Local profile + laboratory prior; a rough model estimate.")
                    default: Text("iPhone 17 wired laboratory prior; a rough model estimate.")
                    }
                } else {
                    Text("No complete matching slowdown profile. Actual time may be longer, especially above 80%.")
                        .font(.caption).foregroundStyle(Color.mwMuted)
                }
                if let watts = eta.averageWatts {
                    Text("Smoothed cell power: \(Formatting.watts(watts)) W")
                        .font(.caption).foregroundStyle(Color.mwMuted)
                }
                if monitor.chargeTarget > 80 {
                    Text("Above about 80%, charging slows. System holds or temperature limits can delay charging further; a hold has no predictable resume time.")
                        .font(.caption).foregroundStyle(Color.mwMuted)
                }
            } else { Text(status).font(.headline) }
            if eta.state == .collecting {
                Text("Collecting a short continuous cell-power window; no level increase is required.")
                    .font(.caption).foregroundStyle(Color.mwMuted)
            }
            DisclosureGroup("Power model details") {
                VStack(alignment: .leading, spacing: 6) {
                    if let capacity = eta.capacity {
                        Text("Capacity assumption: \(String(format: "%.1f", capacity.wattHours)) Wh")
                        switch capacity.source {
                        case .reportedMaximum: Text("Reported full-charge capacity × cell voltage; approximate energy.")
                        case .reportedDesign: Text("Reported design capacity × cell voltage; approximate energy.")
                        case .iPhone17Rating: Text("iPhone 17 rated 3692 mAh × measured cell voltage; approximate energy.")
                        case .configured: Text("User-configured battery energy; approximate capacity.")
                        }
                    }
                    if eta.usesHistoricalEnergy {
                        Text("Current-power reference is calibrated by measured cell energy in comparable local charge-level segments.")
                    }
                    Text("Remaining charge is approximated from the level and capacity. Current power is averaged over up to 30 seconds; this reference is not a guaranteed lower bound.")
                    Text("The laboratory prior describes one wired 25°C test. Its full-charge endpoint may differ from the displayed 100%. Unsupported models and wireless charging require local history.")
                    Link("Apple battery and charging data", destination: URL(string: "https://www.apple.com/ie/iphone-17/specs/")!)
                    Link("Laboratory curve source", destination: URL(string: "https://www.chongdiantou.com/archives/1769392865663.html")!)
                }
                .font(.caption).foregroundStyle(Color.mwMuted)
            }
            .font(.caption)
        }
    }
    private func readout(_ seconds: Double) -> some View {
        Text(verbatim: "≈ " + Formatting.duration(seconds))
            .mwReadout(size: 26, animatedValue: Formatting.duration(seconds))
    }
    private var status: LocalizedStringResource {
        switch eta.state {
        case .unplugged: "Connect a charger"
        case .paused: "Charging paused — resume time is unknown"
        case .reached: "Target reached"
        case .noReading: "No charge level reading"
        case .noPower: "No positive cell-power reading"
        case .noCapacity: "Capacity unavailable — set battery energy in Settings"
        case .collecting: "Collecting cell-power samples…"
        case .interrupted: "Observation interrupted — waiting for fresh readings"
        case .estimating: "Estimating…"
        }
    }
}
