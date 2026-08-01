import SwiftUI
import ClocktopusCore
import ServiceManagement

struct PreferencesView: View {
    @EnvironmentObject var state: AppState
    @State private var axGranted = AppObserver.hasAccessibilityPermission

    // Editable runtime settings — seeded from the effective values on appear,
    // written straight through to AppState (which persists + applies live).
    @State private var idleMinutes = 5
    @State private var nudgesPerHour = 2
    @State private var aiToolsText = ""
    @State private var includeExact = false
    @State private var browserDetection = false
    @State private var detectionLeadMinutes = 2
    @State private var switchLeadMinutes = 10
    @State private var idleAutoStopMinutes = 120
    @State private var dayStartHour = 4

    var body: some View {
        Form {
            Section("Config") {
                LabeledContent("Personal config", value: AppState.personalConfigURL.path)
                LabeledContent("Team config", value: state.personal?.teamConfigPath ?? "—")
                LabeledContent("Employee", value: state.personal?.employee ?? "—")
                LabeledContent("Rounding",
                               value: String(format: "%.2fh", state.team?.roundingIncrementHours ?? 0.25))
                if let error = state.configError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                Button("Reload config") { state.reloadConfig() }
            }

            Section("Detection & nudges") {
                Stepper("Idle threshold: \(idleMinutes) min",
                        value: Binding(get: { idleMinutes },
                                       set: { idleMinutes = $0
                                              state.setIdleThresholdSeconds(Double($0) * 60) }),
                        in: 1...60)
                VStack(alignment: .leading, spacing: 2) {
                    Stepper("Detection delay: \(detectionLeadMinutes) min",
                            value: Binding(get: { detectionLeadMinutes },
                                           set: { detectionLeadMinutes = $0
                                                  state.setClockInLeadMinutes(Double($0)) }),
                            in: 1...15)
                    Text("How long you must stay on a project before it's detected. Lower = snappier, higher = fewer stray suggestions.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Stepper("Switch suggestion after: \(switchLeadMinutes) min",
                            value: Binding(get: { switchLeadMinutes },
                                           set: { switchLeadMinutes = $0
                                                  state.setSwitchLeadMinutes(Double($0)) }),
                            in: 2...30)
                    Text("While a timer runs, how long another project must dominate before Clocktopus suggests switching.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Stepper(idleAutoStopMinutes == 0
                            ? "Auto clock-out when idle: never"
                            : "Auto clock-out when idle: \(idleAutoStopMinutes) min",
                            value: Binding(get: { idleAutoStopMinutes },
                                           set: { idleAutoStopMinutes = $0
                                                  state.setIdleAutoStopMinutes($0) }),
                            in: 0...480, step: 15)
                    Text("Idle longer than this stops the running timer at the moment you went idle, so an overnight never bills. Shorter breaks just ask on your return. 0 = never auto-stop.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Stepper("Nudges per hour: \(nudgesPerHour)",
                        value: Binding(get: { nudgesPerHour },
                                       set: { nudgesPerHour = $0
                                              state.setNudgesPerHour($0) }),
                        in: 0...10)
                VStack(alignment: .leading, spacing: 2) {
                    TextField("AI tools (comma-separated)", text: $aiToolsText)
                        .onSubmit { commitAITools() }
                    Text("Processes whose working directory signals active work, e.g. claude, codex, gemini.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Include exact-hours column in export",
                       isOn: Binding(get: { includeExact },
                                     set: { includeExact = $0
                                            state.setIncludeExactColumn($0) }))
                VStack(alignment: .leading, spacing: 2) {
                    Toggle("Detect browser activity",
                           isOn: Binding(get: { browserDetection },
                                         set: { browserDetection = $0
                                                state.setBrowserDetectionEnabled($0) }))
                    Text("Reads the active tab URL of the frontmost browser (Safari, Chrome, Brave, Edge, Arc) to match projects. macOS will ask permission per browser; only the domain is stored.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Day boundary") {
                VStack(alignment: .leading, spacing: 2) {
                    Stepper("Day starts at \(String(format: "%02d", dayStartHour)):00",
                            value: Binding(get: { dayStartHour },
                                           set: { dayStartHour = $0
                                                  state.setDayStartHour($0) }),
                            in: 0...23)
                    Text("Work before this hour counts toward the previous day, so late-night sessions don't split across two days in totals and the xledger export.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Permissions") {
                LabeledContent("Accessibility (window titles)") {
                    if axGranted {
                        Label("Granted", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Button("Open System Settings") {
                            AppObserver.requestAccessibilityPermission()
                            NSWorkspace.shared.open(URL(string:
                                "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                        }
                    }
                }
            }

            Section("Startup") {
                Toggle("Launch at login", isOn: Binding(
                    get: { SMAppService.mainApp.status == .enabled },
                    set: { enable in
                        do {
                            if enable { try SMAppService.mainApp.register() }
                            else { try SMAppService.mainApp.unregister() }
                        } catch {
                            NSLog("launch-at-login toggle failed: %@", "\(error)")
                        }
                    }))
            }
        }
        .formStyle(.grouped)
        // Opaque title bar: without this the form scrolls up underneath a
        // transparent bar and shows through the traffic lights.
        .toolbarBackground(.visible, for: .windowToolbar)
        .frame(width: 460)
        .onAppear {
            axGranted = AppObserver.hasAccessibilityPermission
            idleMinutes = max(1, Int((state.effectiveIdleThreshold / 60).rounded()))
            nudgesPerHour = state.effectiveNudgesPerHour
            aiToolsText = state.effectiveAITools.joined(separator: ", ")
            includeExact = state.effectiveIncludeExactColumn
            browserDetection = state.browserDetectionEnabled
            detectionLeadMinutes = max(1, Int(state.effectiveClockInLeadMinutes.rounded()))
            switchLeadMinutes = max(2, Int(state.effectiveSwitchLeadMinutes.rounded()))
            idleAutoStopMinutes = max(0, state.effectiveIdleAutoStopMinutes)
            dayStartHour = state.effectiveDayStartHour
        }
        // Catch an edit the user typed but didn't press Return on.
        .onDisappear { commitAITools() }
    }

    /// Parse the comma-separated field into a trimmed, non-empty tool list and
    /// persist it. An empty field clears the override (falls back to config/default).
    private func commitAITools() {
        let tools = aiToolsText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        state.setAITools(tools)
    }
}
