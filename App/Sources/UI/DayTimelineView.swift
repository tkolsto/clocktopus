import SwiftUI
import ClocktopusCore

/// Vertical day timeline. Logged entries are solid coloured cards; detected-
/// but-unverified activity shows as dashed "ghost" cards. Both can be dragged
/// to resize and lay out in side-by-side columns when they overlap. Clicking a
/// ghost card opens a floating panel to confirm or dismiss it.
struct DayTimelineView: View {
    @EnvironmentObject var state: AppState
    let day: Date

    @State private var editing: TimeEntry?
    @State private var creatingAt: CreationAnchor?
    @State private var dragPreview: DragPreview?
    @State private var isResizing = false
    @State private var hovered: UUID?
    @State private var reviewing: ProvisionalBlock?
    @State private var dragEdge: ResizeEdge?
    @State private var didInitialScroll = false

    private static let snapSeconds: TimeInterval = 300
    private static let minDuration: TimeInterval = 300
    private static let handleHeight: CGFloat = 9
    private static let hourHeight: CGFloat = 56
    private static let minEntryHeight: CGFloat = 16
    private static let leftGutter: CGFloat = 44
    private static let rightPad: CGFloat = 10
    private static let columnGap: CGFloat = 3
    private static let panelWidth: CGFloat = 280

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private var dayInterval: DateInterval { state.workday.dayInterval(for: day) }
    private var entries: [TimeEntry] { (try? state.store.entries(in: dayInterval)) ?? [] }
    private var blocks: [ProvisionalBlock] {
        state.pendingBlocks.filter { $0.end > $0.start && dayInterval.intersects(DateInterval(start: $0.start, end: $0.end)) }
    }

    private enum Item: Identifiable {
        case entry(TimeEntry)
        case block(ProvisionalBlock)
        var id: String {
            switch self {
            case .entry(let e): return "e-\(e.id.uuidString)"
            case .block(let b): return "b-\(b.id.uuidString)"
            }
        }
    }
    private var items: [Item] { entries.map(Item.entry) + blocks.map(Item.block) }

    /// Hour row to open scrolled to: the current hour today, else ~09:00.
    private var scrollTargetHour: Int {
        let now = Date()
        let target = dayInterval.contains(now) ? now : dayInterval.start.addingTimeInterval(5 * 3600)
        return min(max(Int(target.timeIntervalSince(dayInterval.start) / 3600), 0), 23)
    }

    var body: some View {
        // Periodic re-render so the timeline reflects current activity (an
        // extending block, new entries, the "now" line) even while the window
        // sits inactive — SwiftUI otherwise defers redraws for a background
        // accessory window until it's refocused.
        TimelineView(.periodic(from: .now, by: 30)) { context in
            GeometryReader { geo in
                ScrollViewReader { proxy in
                    ScrollView {
                        ZStack(alignment: .topLeading) {
                            hourGrid
                            let places = placements()
                            ForEach(items) { item in
                                itemView(item, place: places[item.id] ?? Placement(column: 0, columns: 1),
                                         containerWidth: geo.size.width)
                            }
                            nowLine(context.date)
                            if let block = reviewing {
                                reviewOverlay(block, places: places, containerWidth: geo.size.width)
                            } else if let hb = blocks.first(where: { $0.id == hovered }) {
                                hovercard(hb, places: places, containerWidth: geo.size.width)
                            }
                        }
                        .frame(height: Self.hourHeight * 24)
                    }
                    .scrollDisabled(isResizing)
                    .onAppear {
                        // Open scrolled to "now" (today) or ~09:00 otherwise.
                        guard !didInitialScroll else { return }
                        didInitialScroll = true
                        DispatchQueue.main.async {
                            proxy.scrollTo(scrollTargetHour, anchor: .center)
                        }
                    }
                }
            }
        }
        .sheet(item: $editing) { entry in
            EntryEditorSheet(entry: entry, defaultStart: entry.start)
        }
        .sheet(item: $creatingAt) { anchor in
            EntryEditorSheet(entry: nil, defaultStart: anchor.date)
        }
    }

    /// A live "now" marker on today's timeline.
    @ViewBuilder
    private func nowLine(_ now: Date) -> some View {
        if dayInterval.contains(now) {
            ZStack(alignment: .leading) {
                Rectangle().fill(.red.opacity(0.85)).frame(height: 1.5)
                Circle().fill(.red).frame(width: 7, height: 7)
            }
            .padding(.leading, Self.leftGutter - 3.5)
            .offset(y: yOffset(for: now) - 0.75)
        }
    }

    @ViewBuilder
    private func itemView(_ item: Item, place: Placement, containerWidth: CGFloat) -> some View {
        switch item {
        case .entry(let e): entryBlock(e, place: place, containerWidth: containerWidth)
        case .block(let b): ghostBlock(b, place: place, containerWidth: containerWidth)
        }
    }

    private var hourGrid: some View {
        VStack(spacing: 0) {
            ForEach(0..<24, id: \.self) { row in
                let clockHour = (state.effectiveDayStartHour + row) % 24
                HStack(alignment: .top, spacing: 6) {
                    Text(String(format: "%02d", clockHour))
                        .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                        .frame(width: 30, alignment: .trailing)
                    Rectangle().fill(.quaternary).frame(height: 1)
                }
                .frame(height: Self.hourHeight, alignment: .top)
                .contentShape(Rectangle())
                .onTapGesture {
                    let start = Calendar.current.date(byAdding: .hour, value: row, to: dayInterval.start)!
                    creatingAt = CreationAnchor(date: start)
                }
            }
        }
    }

    // MARK: - Column layout

    private struct Placement { let column: Int; let columns: Int }

    private func displayStart(_ id: UUID, _ fallback: Date) -> Date {
        (dragPreview?.id == id ? dragPreview?.start : nil) ?? fallback
    }
    private func displayEnd(_ id: UUID, _ fallback: Date) -> Date {
        (dragPreview?.id == id ? dragPreview?.end : nil) ?? fallback
    }
    private func itemStart(_ item: Item) -> Date {
        switch item {
        case .entry(let e): return displayStart(e.id, e.start)
        case .block(let b): return displayStart(b.id, b.start)
        }
    }
    private func itemEnd(_ item: Item) -> Date {
        switch item {
        case .entry(let e): return displayEnd(e.id, e.end ?? Date())
        case .block(let b): return displayEnd(b.id, b.end)
        }
    }

    private func placements() -> [String: Placement] {
        let sorted = items.sorted { itemStart($0) < itemStart($1) }
        func topBottom(_ i: Item) -> (CGFloat, CGFloat) {
            let top = yOffset(for: itemStart(i))
            return (top, top + height(from: itemStart(i), to: itemEnd(i)))
        }
        var result: [String: Placement] = [:]
        var cluster: [Item] = []
        var clusterBottom: CGFloat = -1

        func flush() {
            guard !cluster.isEmpty else { return }
            var columnBottoms: [CGFloat] = []
            var col: [String: Int] = [:]
            for i in cluster {
                let (top, bottom) = topBottom(i)
                var placed = false
                for c in columnBottoms.indices where columnBottoms[c] <= top + 0.5 {
                    columnBottoms[c] = bottom; col[i.id] = c; placed = true; break
                }
                if !placed { col[i.id] = columnBottoms.count; columnBottoms.append(bottom) }
            }
            for i in cluster { result[i.id] = Placement(column: col[i.id]!, columns: columnBottoms.count) }
            cluster = []; clusterBottom = -1
        }

        for i in sorted {
            let (top, bottom) = topBottom(i)
            if cluster.isEmpty || top < clusterBottom - 0.5 {
                cluster.append(i); clusterBottom = max(clusterBottom, bottom)
            } else {
                flush(); cluster = [i]; clusterBottom = bottom
            }
        }
        flush()
        return result
    }

    private func yOffset(for date: Date) -> CGFloat {
        CGFloat(max(0, date.timeIntervalSince(dayInterval.start)) / 3600) * Self.hourHeight
    }

    private func height(from start: Date, to end: Date) -> CGFloat {
        let clippedStart = max(start, dayInterval.start)
        let clippedEnd = min(end, dayInterval.end)
        let raw = CGFloat(clippedEnd.timeIntervalSince(clippedStart) / 3600) * Self.hourHeight
        return max(Self.minEntryHeight, raw)
    }

    private func columnFrame(_ place: Placement, _ containerWidth: CGFloat) -> (x: CGFloat, w: CGFloat) {
        let usable = max(0, containerWidth - Self.leftGutter - Self.rightPad)
        let colWidth = usable / CGFloat(place.columns)
        return (Self.leftGutter + CGFloat(place.column) * colWidth, max(0, colWidth - Self.columnGap))
    }

    private func timeRange(_ start: Date, _ end: Date) -> String {
        "\(Self.timeFormatter.string(from: start))–\(Self.timeFormatter.string(from: end))"
    }

    // MARK: - Cards

    private func entryBlock(_ entry: TimeEntry, place: Placement, containerWidth: CGFloat) -> some View {
        let start = displayStart(entry.id, entry.start)
        let end = displayEnd(entry.id, entry.end ?? Date())
        let name = state.project(entry.projectId)?.name ?? entry.projectId
        let color = state.color(for: entry.projectId)
        let h = height(from: start, to: end)
        let resizable = entry.end != nil
        let showGrips = resizable && (hovered == entry.id || dragPreview?.id == entry.id)
        let frame = columnFrame(place, containerWidth)

        return RoundedRectangle(cornerRadius: 6)
            .fill(color.gradient)
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
            .overlay(alignment: .topLeading) { label(name, timeRange(start, end), h: h, color: .white) }
            .overlay(alignment: .top) { if showGrips { resizeHandle(id: entry.id, start: entry.start, end: entry.end ?? Date(), edge: .top) } }
            .overlay(alignment: .bottom) { if showGrips { resizeHandle(id: entry.id, start: entry.start, end: entry.end ?? Date(), edge: .bottom) } }
            .frame(width: frame.w, height: h, alignment: .topLeading)
            .position(x: frame.x + frame.w / 2, y: yOffset(for: start) + h / 2)
            .onHover { hovered = $0 ? entry.id : (hovered == entry.id ? nil : hovered) }
            .onTapGesture { editing = entry }
            .help(name)
    }

    private func ghostBlock(_ block: ProvisionalBlock, place: Placement, containerWidth: CGFloat) -> some View {
        let start = displayStart(block.id, block.start)
        let end = displayEnd(block.id, block.end)
        let color = block.guessedProjectId.map { state.color(for: $0) } ?? .gray
        let name = block.guessedProjectId.flatMap { state.project($0)?.name } ?? "Unknown"
        let h = height(from: start, to: end)
        let showGrips = hovered == block.id || dragPreview?.id == block.id
        let frame = columnFrame(place, containerWidth)

        return RoundedRectangle(cornerRadius: 6)
            .fill(color.opacity(0.14))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(color.opacity(0.75), style: StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
            )
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 3) {
                        Text("\(name)?").font(.caption.weight(.medium)).foregroundStyle(color).lineLimit(1)
                        ForEach(SignalKind.displayOrder.filter { block.signals.contains($0) }, id: \.self) { kind in
                            Image(systemName: kind.symbolName).font(.system(size: 8.5)).foregroundStyle(color.opacity(0.75))
                        }
                    }
                    if h >= 30 {
                        Text(timeRange(start, end)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .padding(.horizontal, 7).padding(.vertical, 3)
            }
            .overlay(alignment: .top) { if showGrips { resizeHandle(id: block.id, start: block.start, end: block.end, edge: .top, tint: color) } }
            .overlay(alignment: .bottom) { if showGrips { resizeHandle(id: block.id, start: block.start, end: block.end, edge: .bottom, tint: color) } }
            .frame(width: frame.w, height: h, alignment: .topLeading)
            .position(x: frame.x + frame.w / 2, y: yOffset(for: start) + h / 2)
            .onHover { hovered = $0 ? block.id : (hovered == block.id ? nil : hovered) }
            .onTapGesture { reviewing = block }
            .help(block.evidence)
    }

    private func label(_ name: String, _ time: String, h: CGFloat, color: Color, secondaryTime: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(name).font(.caption.weight(.semibold)).foregroundStyle(color).lineLimit(1)
            if h >= 30 {
                Text(time).font(.caption2).foregroundStyle(secondaryTime ? Color.secondary : color.opacity(0.9)).lineLimit(1)
            }
        }
        .shadow(color: secondaryTime ? .clear : .black.opacity(0.25), radius: 0.5, y: 0.5)
        .padding(.horizontal, 7).padding(.vertical, 3)
    }

    // MARK: - Review panel

    private func reviewOverlay(_ block: ProvisionalBlock, places: [String: Placement], containerWidth: CGFloat) -> some View {
        let place = places[Item.block(block).id] ?? Placement(column: 0, columns: 1)
        let frame = columnFrame(place, containerWidth)
        let blockH = height(from: block.start, to: block.end)
        let px = min(max(Self.leftGutter, frame.x), max(Self.leftGutter, containerWidth - Self.panelWidth - 10))
        let py = yOffset(for: block.start) + blockH + 6

        return ZStack(alignment: .topLeading) {
            Rectangle().fill(.black.opacity(0.2))
                .frame(width: containerWidth, height: Self.hourHeight * 24)
                .contentShape(Rectangle())
                .onTapGesture { reviewing = nil }
            GhostReviewPanel(block: block, onDone: { reviewing = nil })
                .frame(width: Self.panelWidth)
                .offset(x: px, y: py)
        }
        .frame(width: containerWidth, height: Self.hourHeight * 24, alignment: .topLeading)
    }

    /// A non-interactive hovercard with the full evidence, shown while hovering
    /// a ghost card (the icons give the glance; this gives the detail).
    private func hovercard(_ block: ProvisionalBlock, places: [String: Placement], containerWidth: CGFloat) -> some View {
        let place = places[Item.block(block).id] ?? Placement(column: 0, columns: 1)
        let frame = columnFrame(place, containerWidth)
        let blockH = height(from: block.start, to: block.end)
        let cardW: CGFloat = 260
        let px = min(max(Self.leftGutter, frame.x), max(Self.leftGutter, containerWidth - cardW - 10))
        let py = yOffset(for: block.start) + blockH + 4

        return ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 3) {
                Text(timeRange(block.start, block.end)).font(.caption.weight(.semibold))
                if !block.evidence.isEmpty {
                    Text(block.evidence).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(8)
            .frame(width: cardW, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .windowBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary, lineWidth: 1))
            .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
            .offset(x: px, y: py)
        }
        .frame(width: containerWidth, height: Self.hourHeight * 24, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    // MARK: - Resize (entries and ghost blocks alike)

    private enum ResizeEdge { case top, bottom }

    private func resizeHandle(id: UUID, start: Date, end: Date, edge: ResizeEdge, tint: Color = .white) -> some View {
        Rectangle()
            .fill(Color.white.opacity(0.001))
            .frame(height: Self.handleHeight)
            .overlay(Capsule().fill(tint.opacity(0.8)).frame(width: 26, height: 3))
            .contentShape(Rectangle())
            .highPriorityGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        isResizing = true
                        updateDrag(id: id, start: start, end: end, edge: edge, translationY: value.translation.height)
                    }
                    .onEnded { _ in commitDrag(); isResizing = false }
            )
    }

    private func updateDrag(id: UUID, start: Date, end: Date, edge: ResizeEdge, translationY: CGFloat) {
        // Smooth (unsnapped) while dragging; snapping happens on release so the
        // block doesn't visibly jump in 5-minute steps under the cursor.
        let delta = TimeInterval(translationY / Self.hourHeight) * 3600
        let bounds = neighborBounds(excluding: id, start: start, end: end)
        dragEdge = edge
        switch edge {
        case .top:
            let s = min(max(start.addingTimeInterval(delta), bounds.lower),
                        end.addingTimeInterval(-Self.minDuration))
            dragPreview = DragPreview(id: id, start: s, end: end)
        case .bottom:
            let e = max(min(end.addingTimeInterval(delta), bounds.upper),
                        start.addingTimeInterval(Self.minDuration))
            dragPreview = DragPreview(id: id, start: start, end: e)
        }
    }

    private func commitDrag() {
        defer { dragPreview = nil; dragEdge = nil }
        guard let p = dragPreview else { return }
        // Snap only the edge that moved, then keep the minimum duration.
        var s = p.start, e = p.end
        if dragEdge == .top {
            s = snap(p.start)
            if e.timeIntervalSince(s) < Self.minDuration { s = e.addingTimeInterval(-Self.minDuration) }
        } else {
            e = snap(p.end)
            if e.timeIntervalSince(s) < Self.minDuration { e = s.addingTimeInterval(Self.minDuration) }
        }
        if var entry = entries.first(where: { $0.id == p.id }) {
            entry.start = s; entry.end = e; state.saveResizedEntry(entry)
        } else if var block = blocks.first(where: { $0.id == p.id }) {
            block.start = s; block.end = e; state.saveResizedBlock(block)
        }
    }

    private func snap(_ date: Date) -> Date {
        let t = date.timeIntervalSinceReferenceDate
        return Date(timeIntervalSinceReferenceDate: (t / Self.snapSeconds).rounded() * Self.snapSeconds)
    }

    /// Clamp an edge at the nearest neighbour (entry or ghost) so a resize can
    /// never create an overlap.
    private func neighborBounds(excluding id: UUID, start: Date, end: Date) -> (lower: Date, upper: Date) {
        var lower = dayInterval.start
        var upper = dayInterval.end
        func consider(_ oid: UUID, _ s: Date, _ e: Date) {
            guard oid != id else { return }
            if e <= start { lower = max(lower, e) }
            if s >= end { upper = min(upper, s) }
        }
        for e in entries { consider(e.id, e.start, e.end ?? Date()) }
        for b in blocks { consider(b.id, b.start, b.end) }
        return (lower, upper)
    }
}

/// Floating panel to confirm or dismiss an unverified ghost block.
private struct GhostReviewPanel: View {
    @EnvironmentObject var state: AppState
    let block: ProvisionalBlock
    let onDone: () -> Void
    @State private var chosen = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Detected activity").font(.headline)
            if !block.evidence.isEmpty {
                Text(block.evidence).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Picker("Project", selection: $chosen) {
                Text("Choose project…").tag("")
                ForEach(state.projects) { Text($0.name).tag($0.id) }
            }
            .labelsHidden()
            HStack {
                Button("Dismiss") { state.dismissBlock(block); onDone() }
                Spacer()
                Button("Log it") { state.acceptBlock(block, projectId: chosen); onDone() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(chosen.isEmpty)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary, lineWidth: 1))
        .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
        .onAppear {
            chosen = block.guessedProjectId.flatMap { g in state.projects.first { $0.id == g }?.id } ?? ""
        }
    }
}

struct DragPreview: Equatable {
    let id: UUID
    var start: Date
    var end: Date
}

/// Wraps a `Date` as a sheet item (Date has no natural Identifiable and a
/// retroactive conformance warns under SWIFT_VERSION 5.10).
struct CreationAnchor: Identifiable {
    let id: TimeInterval
    let date: Date

    init(date: Date) {
        self.date = date
        self.id = date.timeIntervalSince1970
    }
}
