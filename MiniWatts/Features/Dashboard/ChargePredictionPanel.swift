import SwiftUI

struct ChargePredictionPanel: View {
    @Environment(PowerMonitor.self) private var monitor
    var body: some View {
        Panel("Charge prediction", systemImage: "clock.badge.checkmark") {
            VStack(alignment: .leading, spacing: 10) {
                Stepper("Target \(monitor.chargeTarget)%", value: Binding(get: { monitor.chargeTarget }, set: { monitor.chargeTarget = $0 }), in: 50...100)
                HStack {
                    ForEach([80, 90, 100], id: \.self) { target in
                        Button { monitor.chargeTarget = target } label: { Text(verbatim: "\(target)%") }
                            .buttonStyle(.bordered).tint(monitor.chargeTarget == target ? .mwAccent : .mwMuted)
                    }
                }
                if let seconds = monitor.chargeETA.seconds, monitor.chargeETA.state == .estimating {
                    Text(verbatim: "≈ " + Formatting.duration(seconds)).mwReadout(size: 28)
                    switch monitor.chargeETA.source {
                    case .history: Text("Historical segments; \(monitor.chargeETA.historyCount) comparable records per segment.")
                    case .hybrid: Text("Recent trend + historical segments; some portions may be extrapolated.")
                    default: Text("Recent trend only — rough estimate; charging may slow near full.")
                    }
                } else { Text(status).font(.headline) }
                Text("An estimate to your target, not a system charging limit or guaranteed finish time.")
                    .font(.caption).foregroundStyle(Color.mwMuted)
            }
        }
    }
    private var status: LocalizedStringResource {
        switch monitor.chargeETA.state {
        case .unplugged: "Connect a charger"
        case .paused: "Charging paused"
        case .noReading: "No charge level reading"
        case .interrupted: "Observation interrupted — rebuilding the estimate"
        case .collecting: "Collecting charge data…"
        case .reached: "Target reached"
        case .estimating: "Estimating…"
        }
    }
}
