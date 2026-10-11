import SwiftUI

nonisolated enum AnalysisPeriod: String, CaseIterable, Identifiable {
    case week, month, quarter, all, custom
    var id: Self { self }
    var title: LocalizedStringResource {
        switch self {
        case .week: "7 days"
        case .month: "30 days"
        case .quarter: "90 days"
        case .all: "All time"
        case .custom: "Custom dates"
        }
    }
}

extension ChargeSession {
    var titleText: Text { adapterName.map { Text(verbatim: $0) } ?? Text(fallbackTitle) }
    var measuredPeakInputWatts: Double? { totals.inputMeasuredSeconds > 0 ? peakInputWatts : nil }
}

struct SessionsView: View {
    @Environment(PowerMonitor.self) private var monitor
    @State private var section = 0
    @State private var period = AnalysisPeriod.month
    @State private var fromDate = Date.now.addingTimeInterval(-30 * 86400)
    @State private var toDate = Date.now
    @State private var lower = 20
    @State private var upper = 80
    @State private var deleting: Set<UUID> = []

    private var filtered: [ChargeSession] {
        let start: Date
        switch period {
        case .week: start = .now.addingTimeInterval(-7 * 86400)
        case .month: start = .now.addingTimeInterval(-30 * 86400)
        case .quarter: start = .now.addingTimeInterval(-90 * 86400)
        case .all: start = .distantPast
        case .custom: start = Calendar.current.startOfDay(for: fromDate)
        }
        let end = period == .custom ? Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: toDate))! : .distantFuture
        return monitor.sessions.filter { $0.start >= start && $0.start < end }
    }

    var body: some View {
        PageScaffold("Analysis", glow: .mwBattery) {
            Picker("View", selection: $section) {
                Text("Overview").tag(0)
                Text("Records").tag(1)
            }.pickerStyle(.segmented)
            filterPanel
            if let error = monitor.historyError { HistoryErrorPanel(message: error) }
            if !monitor.isLoaded { ProgressView("Loading history…") }
            if section == 0 {
                overviewPanel
                rangePanel
                rankingPanel(wireless: false)
                rankingPanel(wireless: true)
            } else {
                if let current = monitor.currentSession {
                    Panel("In progress", systemImage: "bolt.fill") {
                        Text(verbatim: current.levelDescription)
                        Text("This record remains active during history cleanup.").font(.caption).foregroundStyle(Color.mwMuted)
                    }
                }
                if filtered.isEmpty {
                    Panel("No finished charges yet", systemImage: "clock.arrow.circlepath") {
                        EmptyNote(text: "Connect a charger to start recording. Keep the app running to observe the charge.")
                    }
                }
                ForEach(filtered) { session in
                    NavigationLink { SessionDetailView(session: session) } label: { SessionRow(session: session) }
                        .buttonStyle(.plain)
                }
            }
            storagePanel
        }
        .confirmationDialog(Text("Delete \(deleting.count) saved sessions?"), isPresented: deletionBinding, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { monitor.deleteSessions(ids: deleting); deleting = [] }
            Button("Cancel", role: .cancel) { deleting = [] }
        } message: { Text("The current charge is kept. This cannot be undone.") }
    }
    private var deletionBinding: Binding<Bool> {
        Binding(get: { !deleting.isEmpty }, set: { if !$0 { deleting = [] } })
    }
    private var filterPanel: some View {
        Panel("Date range", systemImage: "calendar") {
            Picker("Date range", selection: $period) {
                ForEach(AnalysisPeriod.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.menu)
            if period == .custom {
                DatePicker("From date", selection: $fromDate, in: ...toDate, displayedComponents: .date)
                DatePicker("To date", selection: $toDate, in: fromDate..., displayedComponents: .date)
            }
            Text("Includes complete sessions whose start time falls in this range.")
                .font(.caption).foregroundStyle(Color.mwMuted)
        }
    }
    private var overviewPanel: some View {
        let totals = AnalysisTotals(sessions: filtered)
        return Panel("Overview", systemImage: "chart.bar", trailing: Text("\(filtered.count) sessions")) {
            VStack(spacing: 12) {
                HStack {
                    Metric(caption: "Delivered", value: value(totals.inputWh), unit: "Wh", tint: .mwAccent, size: 20)
                    Metric(caption: "Stored", value: value(totals.batteryWh), unit: "Wh", tint: .mwBattery, size: 20)
                    Metric(caption: "Cell share", value: value(totals.cellShare), unit: "%", size: 20)
                }
                HStack {
                    Metric(caption: "Average in", value: value(totals.averageInputWatts), unit: "W", size: 18)
                    Metric(caption: "Average cell", value: value(totals.averageBatteryWatts), unit: "W", size: 18)
                    Metric(caption: "Average cell temp", value: value(totals.averageTemperature), unit: "°C", size: 18)
                }
                DetailRow(label: "Load + loss", value: totals.loadAndLossWh.map { "\(value($0)) Wh" })
                DetailRow(label: "Observation coverage", value: filtered.isEmpty ? nil : "\(Int(totals.coverage * 100))%")
                ReportExportButton(sessions: filtered, lower: lower, upper: upper, isSingle: false)
            }
        }
    }
    private var rangePanel: some View {
        Panel("Comparable charge range", systemImage: "slider.horizontal.3") {
            Stepper("From \(lower)%", value: $lower, in: 0...(upper - 1), step: 5)
            Stepper("To \(upper)%", value: $upper, in: (lower + 1)...100, step: 5)
            Text("Only complete observed ranges with at least 90% coverage are ranked. Wired and wireless are compared separately.")
                .font(.caption).foregroundStyle(Color.mwMuted)
        }
    }
    private func rankingPanel(wireless: Bool) -> some View {
        let matching = filtered.filter { $0.isWireless == wireless }
        let ranked = matching.compactMap { session -> RankedSession? in
            guard let seconds = ChargeAnalysis.comparableSeconds(session, from: lower, to: upper) else { return nil }
            return RankedSession(session: session, seconds: seconds)
        }.sorted { $0.seconds < $1.seconds }
        return Panel(wireless ? "Wireless comparison" : "Wired comparison", systemImage: wireless ? "wave.3.right" : "powerplug") {
            VStack(alignment: .leading, spacing: 8) {
                if ranked.count < 2 { EmptyNote(text: "Not enough comparable sessions yet.") }
                ForEach(Array(ranked.prefix(10))) { row in
                    NavigationLink { SessionDetailView(session: row.session) } label: {
                        HStack {
                            Text(verbatim: Formatting.timestamp(row.session.start)).font(.caption)
                            Spacer()
                            Text(verbatim: Formatting.duration(row.seconds)).mwMono(size: 14)
                        }
                    }
                }
                Text("\(matching.count - ranked.count) records excluded: incomplete range or insufficient coverage.")
                    .font(.caption).foregroundStyle(Color.mwMuted)
                Text("Charger names and thermal pressure alone do not identify a charger or prove why charging slowed.")
                    .font(.caption2).foregroundStyle(Color.mwMuted)
            }
        }
    }
    private var storagePanel: some View {
        Panel("History storage", systemImage: "externaldrive") {
            Text(verbatim: ByteCountFormatter.string(fromByteCount: monitor.historyBytes, countStyle: .file))
            Text("All recorded samples are retained until you delete them.").font(.caption).foregroundStyle(Color.mwMuted)
            Button("Delete records in this date range", role: .destructive) { deleting = Set(filtered.map(\.id)) }
                .disabled(filtered.isEmpty || !monitor.isLoaded)
            Button("Delete all saved sessions", role: .destructive) { deleting = Set(monitor.sessions.map(\.id)) }
                .disabled(monitor.sessions.isEmpty || !monitor.isLoaded)
        }
    }
}

nonisolated struct RankedSession: Identifiable {
    let session: ChargeSession
    let seconds: Double
    var id: UUID { session.id }
}

private func value(_ number: Double?) -> String { number.map { String(format: "%.1f", $0) } ?? "—" }

struct HistoryErrorPanel: View {
    let message: String
    var body: some View {
        Panel("History needs attention", systemImage: "exclamationmark.triangle") {
            Text(verbatim: message).font(.caption).foregroundStyle(Color.mwDanger)
        }
    }
}

struct SessionRow: View {
    let session: ChargeSession
    var body: some View {
        Panel {
            VStack(spacing: 8) {
                HStack {
                    VStack(alignment: .leading) {
                        session.titleText.font(.subheadline.weight(.semibold))
                        Text(verbatim: Formatting.timestamp(session.start)).font(.caption).foregroundStyle(Color.mwMuted)
                    }
                    Spacer()
                    Text(verbatim: session.levelDescription).mwMono(size: 12)
                }
                HStack {
                    Sparkline(values: session.previewPower, tint: session.isWireless ? .mwWireless : .mwAccent).frame(height: 26)
                    Text("\(Int(session.coverage * 100))% observed").font(.caption2).foregroundStyle(Color.mwMuted)
                }
            }
        }
    }
}

struct SessionDetailView: View {
    let session: ChargeSession
    @Environment(PowerMonitor.self) private var monitor
    @Environment(\.dismiss) private var dismiss
    @State private var detail: ChargeSession?
    @State private var loadError: String?
    @State private var confirmingDelete = false
    private var record: ChargeSession { detail ?? session }
    var body: some View {
        ZStack {
            Backdrop(glow: .mwBattery)
            ScrollView {
                LazyVStack(spacing: 14) {
                    if let loadError { HistoryErrorPanel(message: loadError) }
                    if detail == nil && loadError == nil { ProgressView("Loading curve…") }
                    metricsPanel
                    if let detail {
                        Panel("Charge curve", systemImage: "chart.xyaxis.line") { SessionPowerChart(samples: detail.samples) }
                        Panel("Level and temperature", systemImage: "thermometer.variable") { SessionClimateChart(samples: detail.samples) }
                        ReportExportButton(sessions: [detail], lower: 20, upper: 80, isSingle: true)
                    }
                    qualityPanel
                }.padding(16).containerRelativeFrame(.horizontal)
            }
        }
        .navigationTitle(session.titleText)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: session.id) {
            do { detail = try await monitor.loadSession(session.id) }
            catch { loadError = error.localizedDescription }
        }
        .toolbar {
            Button(role: .destructive) { confirmingDelete = true } label: { Image(systemName: "trash") }
        }
        .confirmationDialog("Delete 1 saved session?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { monitor.deleteSession(session); dismiss() }
            Button("Cancel", role: .cancel) {}
        }
    }
    private var metricsPanel: some View {
        Panel("Energy and temperature", systemImage: "bolt.circle") {
            VStack(spacing: 0) {
                DetailRow(label: "Charge level", value: record.levelDescription)
                DetailRow(label: "Target", value: "\(record.targetPercent)%")
                DetailRow(label: "Delivered", value: record.totals.measuredInputWattHours.map { "\(value($0)) Wh" })
                DetailRow(label: "Stored", value: record.measuredBatteryWattHours.map { "\(value($0)) Wh" })
                DetailRow(label: "Cell share", value: record.totals.chargePathEfficiencyPercent.map { "\(value($0))%" })
                DetailRow(label: "Load + loss", value: record.totals.unaccountedWattHours.map { "\(value($0)) Wh" })
                DetailRow(label: "Average in", value: record.totals.averageInputWatts.map { "\(value($0)) W" })
                DetailRow(label: "Average cell", value: record.averageBatteryWatts.map { "\(value($0)) W" })
                DetailRow(label: "Peak from charger", value: record.measuredPeakInputWatts.map { "\(value($0)) W" })
                DetailRow(label: "Peak into cell", value: record.totals.batteryMeasuredSeconds > 0 ? "\(value(record.peakBatteryWatts)) W" : nil)
                DetailRow(label: "Peak cell temp", value: record.peakBatteryTemperature.map { "\(value($0)) °C" })
                DetailRow(label: "Average cell temp", value: session.averageBatteryTemperature.map { "\(value($0)) °C" })
                DetailRow(label: "System thermal pressure", value: Formatting.duration(record.throttledSeconds))
                DetailRow(label: "Path resistance", value: record.pathMilliohms.map { "\(value($0)) mΩ" })
            }
        }
    }
    private var qualityPanel: some View {
        Panel("Data quality", systemImage: "checkmark.shield") {
            VStack(spacing: 0) {
                DetailRow(label: "Started", value: Formatting.timestamp(record.start))
                DetailRow(label: "Ended", value: record.end.map(Formatting.timestamp))
                DetailRow(label: "Device model", value: record.deviceModel)
                DetailRow(label: "System version", value: record.systemVersion)
                DetailRow(label: "Samples", value: "\(detail?.samples.count ?? session.sampleCount)")
                DetailRow(label: "Observation coverage", value: "\(Int(record.coverage * 100))%")
                DetailRow(label: "Input measured", value: Formatting.duration(record.totals.inputMeasuredSeconds))
                DetailRow(label: "Battery measured", value: Formatting.duration(record.totals.batteryMeasuredSeconds))
                if record.interrupted { Text("Recording was interrupted. The end is the last observed time.").font(.caption).foregroundStyle(Color.mwLoss) }
                Text("Gaps are excluded. Load + loss includes the phone's own consumption. Thermal pressure alone does not establish the cause of slow charging.")
                    .font(.caption).foregroundStyle(Color.mwMuted)
            }
        }
    }
}
