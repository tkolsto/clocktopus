import SwiftUI
import ClocktopusCore

struct EntryEditorSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    let entry: TimeEntry?          // nil = creating new
    let defaultStart: Date
    var defaultEnd: Date? = nil    // pre-filled by drag-to-create

    @State private var projectId = ""
    @State private var start = Date()
    @State private var end = Date()
    @State private var note = ""
    @State private var keepRunning = true
    @State private var validationError: String?

    private var isEditingRunningEntry: Bool {
        entry != nil && entry?.end == nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(entry == nil ? "New entry" : "Edit entry").font(.headline)
            if entry?.exportedAt != nil {
                Label("Already exported — edits won't reach xledger automatically",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
            if isEditingRunningEntry {
                // Editing the live timer: default is to keep it running (change
                // project/start in place); flipping the toggle stops it at the
                // chosen end time, the old behavior.
                Toggle(isOn: $keepRunning) {
                    Label("Keep the timer running", systemImage: "record.circle")
                        .font(.caption)
                }
                .toggleStyle(.checkbox)
            }
            Picker("Project", selection: $projectId) {
                ForEach(state.projects) { Text($0.name).tag($0.id) }
            }
            DatePicker("Start", selection: $start)
            if isEditingRunningEntry && keepRunning {
                LabeledContent("End") {
                    Text("still running").foregroundStyle(.secondary)
                }
            } else {
                DatePicker("End", selection: $end)
            }
            TextField("Note", text: $note)
            if let validationError {
                Text(validationError).font(.caption).foregroundStyle(.red)
            }
            HStack {
                if let entry {
                    Button("Delete", role: .destructive) {
                        try? state.store.delete(entryId: entry.id)
                        state.refreshDerived()
                        dismiss()
                    }
                }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(projectId.isEmpty
                              || (isEditingRunningEntry && keepRunning
                                  ? start >= Date() : end <= start))
            }
        }
        .padding()
        .frame(width: 340)
        .onAppear {
            projectId = entry?.projectId ?? state.projects.first?.id ?? ""
            start = entry?.start ?? defaultStart
            keepRunning = isEditingRunningEntry
            if isEditingRunningEntry {
                end = Date()
            } else {
                end = entry?.end ?? defaultEnd ?? defaultStart.addingTimeInterval(3600)
            }
            note = entry?.note ?? ""
        }
    }

    private func save() {
        validationError = nil

        // Keep-running path: project/start/note change in place, end stays nil.
        // Goes through the keeper (it owns the running entry) — saving via the
        // store alone would let the next clock-out resurrect the old fields.
        if isEditingRunningEntry, keepRunning, var running = entry {
            running.projectId = projectId
            running.start = start
            running.end = nil
            running.note = note.isEmpty ? nil : note
            // Clip finished neighbours (and covered ghosts) up to "now".
            state.clearRange(DateInterval(start: start, end: Date()), excludingEntry: running.id)
            state.updateRunningEntry(running)
            dismiss()
            return
        }

        var saved = entry ?? TimeEntry(projectId: projectId, start: start, end: end,
                                       source: .manual)
        saved.projectId = projectId
        saved.start = start
        saved.end = end
        saved.note = note.isEmpty ? nil : note

        if hasRunningNeighborCollision(around: saved) {
            validationError = "Overlaps the running timer — stop it first or adjust times"
            return
        }

        let isRunningEntry = entry?.id == state.runningEntry?.id
        if isRunningEntry, let end = saved.end {
            state.stopRunningEntry(at: end)
        }

        // Whatever sat in this range gives way: neighbours shrink or split,
        // ghosts it covers are answered by the entry itself.
        state.clearRange(DateInterval(start: saved.start, end: saved.end ?? saved.start),
                         excludingEntry: saved.id)
        try? state.store.save(saved)
        state.refreshDerived()
        dismiss()
    }

    /// Detects whether the edited range collides with a *different*, still-running
    /// neighbor entry. Editing the running entry itself is exempt — that path is
    /// handled by `save()` calling `state.stopRunningEntry(at:)` before the upsert,
    /// which keeps the keeper's in-memory state in sync. Silently clipping/deleting
    /// a running neighbor here would desync the keeper instead.
    private func hasRunningNeighborCollision(around saved: TimeEntry) -> Bool {
        guard let savedEnd = saved.end else { return false }
        let dayPad: TimeInterval = 86_400
        let range = DateInterval(start: saved.start.addingTimeInterval(-dayPad),
                                 end: savedEnd.addingTimeInterval(dayPad))
        for other in (try? state.store.entries(in: range)) ?? [] where other.id != saved.id {
            guard other.end == nil else { continue }
            let otherEnd = Date()
            guard other.start < savedEnd, otherEnd > saved.start else { continue }
            return true
        }
        return false
    }

}
