import Foundation

nonisolated enum ReportCSV {
    static func row(_ fields: [String]) -> String {
        fields.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: ",") + "\r\n"
    }
    static func number(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "" }
        return String(format: "%.6g", locale: Locale(identifier: "en_US_POSIX"), value)
    }
    static func timestamp(_ date: Date) -> String { date.ISO8601Format() }
    static let summaryHeader = ["session_id", "start_utc", "end_utc", "device_model", "system_version", "target_percent", "start_percent", "end_percent", "wireless", "duration_seconds", "observation_coverage", "input_Wh", "battery_Wh", "cell_share_percent", "load_and_loss_Wh", "average_input_W", "average_battery_W", "peak_input_W", "peak_battery_W", "peak_battery_C", "average_battery_C", "thermal_pressure_seconds", "sample_count", "interrupted", "adapter", "input_measured_seconds", "battery_measured_seconds", "paired_input_Wh", "paired_battery_Wh", "generated_utc", "app_version", "display_timezone"]
    static let sampleHeader = ["session_id", "sample_utc", "offset_seconds", "percent", "input_W", "battery_W", "battery_C", "hottest_C", "system_thermal_pressure", "is_charging", "observation_break"]
    static func summary(_ session: ChargeSession, generated: Date, appVersion: String, timezone: String) -> String {
        let s = session.samples.isEmpty ? session : session.summary()
        return row([s.id.uuidString, timestamp(s.start), s.end.map(timestamp) ?? "", s.deviceModel, s.systemVersion,
                    String(s.targetPercent), s.startPercent.map(String.init) ?? "", s.endPercent.map(String.init) ?? "",
                    String(s.isWireless), number(s.duration), number(s.coverage), number(s.totals.measuredInputWattHours),
                    number(s.measuredBatteryWattHours), number(s.totals.chargePathEfficiencyPercent), number(s.totals.unaccountedWattHours),
                    number(s.totals.averageInputWatts), number(s.averageBatteryWatts),
                    number(s.totals.inputMeasuredSeconds > 0 ? s.peakInputWatts : nil),
                    number(s.totals.batteryMeasuredSeconds > 0 ? s.peakBatteryWatts : nil),
                    number(s.peakBatteryTemperature), number(s.averageBatteryTemperature), number(s.throttledSeconds),
                    String(s.sampleCount), String(s.interrupted), s.adapterName ?? "", number(s.totals.inputMeasuredSeconds),
                    number(s.totals.batteryMeasuredSeconds), number(s.totals.pairedInputWattHours), number(s.totals.pairedBatteryWattHours),
                    timestamp(generated), appVersion, timezone])
    }
    static func sample(_ sample: ChargeSample, in session: ChargeSession) -> String {
        row([session.id.uuidString, timestamp(session.start.addingTimeInterval(sample.offset)), number(sample.offset),
             sample.percent.map(String.init) ?? "", number(sample.inputWatts), number(sample.batteryWatts),
             number(sample.batteryTemperature), number(sample.hottestTemperature), String(sample.throttled),
             String(sample.isCharging), String(sample.startsNewObservation)])
    }
}
