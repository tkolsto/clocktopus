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
    // Google-calendar-style drag-to-create on empty timeline space.
    @State private var createAnchor: Date?
    @State private var createInterval: DateInterval?
    // Measured overlay heights, for fitting them inside the day content.
    @State private var reviewPanelHeight: CGFloat = 0
    @State private var hovercardHeight: CGFloat = 0

    private static let snapSeconds: TimeInterval = 300
    private static let minDuration: TimeInterval = 300
    private static let handleHeight: CGFloat = 9
    private static let hourHeight: CGFloat = 56
    private static let minEntryHeight: CGFloat = 16
    private static let leftGutter: CGFloat = 44
    private static let rightPad: CGFloat = 10
    private static let columnGap: CGFloat = 3
    private static let panelWidth: CGFloat = 280
    /// Day-content coordinates (scroll-aware) shared by the create gestures.
    private static let contentSpace = "timeline-content"

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
    /// For entries clipped at the day boundary, whose true start is on another
    /// calendar day — "Jul 31 08:47" instead of a misleading bare "08:47".
    private static let dayTimeFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMM d HH:mm"; f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private var dayInterval: DateInterval { state.workday.dayInterval(for: day) }
    private var entries: [TimeEntry] { (try? state.store.entries(in: dayInterval)) ?? [] }
    private var blocks: [ProvisionalBlock] { state.pendingBlocks(in: dayInterval) }

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
                            // Hover is computed by hand from an AppKit tracking
                            // view: SwiftUI's .onHover tracking areas inside a
                            // ScrollView don't follow the scroll offset, so
                            // per-card hover fired on the card scroll-offset
                            // pixels away from the cursor.
                            MouseTrackingView { point in
                                updateHover(point, containerWidth: geo.size.width)
                            }
                            .frame(width: geo.size.width, height: Self.hourHeight * 24)
                            let places = placements()
                            ForEach(items) { item in
                                itemView(item, place: places[item.id] ?? Placement(column: 0, columns: 1),
                                         containerWidth: geo.size.width)
                            }
                            if let interval = createInterval {
                                creationGhost(interval, containerWidth: geo.size.width)
                            }
                            nowLine(context.date).zIndex(5)
                            // Above the hovered card, which zIndexes to 2.
                            if let block = reviewing {
                                reviewOverlay(block, places: places, containerWidth: geo.size.width)
                                    .zIndex(10)
                            } else if let hb = blocks.first(where: { $0.id == hovered }) {
                                hovercard(hb, places: places, containerWidth: geo.size.width)
                                    .zIndex(10)
                            }
                        }
                        .frame(height: Self.hourHeight * 24)
                        .coordinateSpace(name: Self.contentSpace)
                    }
                    .scrollDisabled(isResizing)
                    .onChange(of: reviewing?.id) { id in
                        // The panel can open outside the visible viewport (late
                        // blocks) — bring it into view once it has laid out.
                        guard id != nil else { return }
                        DispatchQueue.main.async {
                            withAnimation(.easeOut(duration: 0.15)) {
                                proxy.scrollTo("review-panel")
                            }
                        }
                    }
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
            EntryEditorSheet(entry: nil, defaultStart: anchor.date, defaultEnd: anchor.end)
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
            }
        }
        .contentShape(Rectangle())
        // Drag out a box on empty space to create an entry (calendar-style);
        // a plain click still opens the editor with a default hour. Logged
        // entries sit above the grid, so drags starting on one never reach
        // this; ghost cards carry the same gesture (see `ghostBlock`).
        .gesture(createGesture(minimumDistance: 0))
    }

    /// Drag-to-create. On the grid a plain click also counts (opens the editor
    /// at that hour); on a ghost card a click is the card's own tap, so the
    /// drag needs some travel before it takes over.
    private func createGesture(minimumDistance: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: minimumDistance, coordinateSpace: .named(Self.contentSpace))
            .onChanged { value in
                isResizing = true          // stop the ScrollView stealing the drag
                if createAnchor == nil { createAnchor = date(atY: value.startLocation.y) }
                let a = createAnchor!, b = date(atY: value.location.y)
                createInterval = DateInterval(start: min(a, b), end: max(a, b))
            }
            .onEnded { value in
                defer { createAnchor = nil; createInterval = nil; isResizing = false }
                guard let a = createAnchor else { return }
                if abs(value.translation.height) < 5 {
                    if minimumDistance == 0 { creatingAt = CreationAnchor(date: snap(a)) }
                    return
                }
                let b = date(atY: value.location.y)
                let s = snap(min(a, b))
                var e = snap(max(a, b))
                if e.timeIntervalSince(s) < Self.minDuration { e = s.addingTimeInterval(Self.minDuration) }
                creatingAt = CreationAnchor(date: s, end: e)
            }
    }

    // MARK: - Hover (manual hit-test)

    @State private var cursorIsResize = false

    /// Resolve which card the mouse is over from raw content coordinates,
    /// matching the render geometry (columns, min height, drag previews).
    /// Later items win on overlap, mirroring ZStack draw order.
    private func updateHover(_ point: CGPoint?, containerWidth: CGFloat) {
        guard let point else {
            hovered = nil
            setResizeCursor(false)
            return
        }
        let places = placements()
        var hit: UUID?
        var nearEdge = false
        for item in items {
            let (id, s, e): (UUID, Date, Date)
            switch item {
            case .entry(let en): (id, s, e) = (en.id, displayStart(en.id, en.start), displayEnd(en.id, en.end ?? Date()))
            case .block(let b): (id, s, e) = (b.id, displayStart(b.id, b.start), displayEnd(b.id, b.end))
            }
            let place = places[item.id] ?? Placement(column: 0, columns: 1)
            let f = columnFrame(place, containerWidth)
            let rect = CGRect(x: f.x, y: yOffset(for: s), width: f.w, height: height(from: s, to: e))
            if rect.contains(point) {
                hit = id
                let zone = Self.gripZoneHeight(cardHeight: rect.height)
                nearEdge = point.y - rect.minY <= zone
                    || rect.maxY - point.y <= zone
            }
        }
        if hovered != hit { hovered = hit }
        setResizeCursor(hit != nil && nearEdge)
    }

    private func setResizeCursor(_ on: Bool) {
        guard on != cursorIsResize else { return }
        cursorIsResize = on
        if on { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
    }

    private func date(atY y: CGFloat) -> Date {
        let clamped = min(max(y, 0), Self.hourHeight * 24)
        return dayInterval.start.addingTimeInterval(TimeInterval(clamped / Self.hourHeight) * 3600)
    }

    /// Live preview of the box being dragged out — tentative until release,
    /// when the editor opens to pick the project.
    private func creationGhost(_ interval: DateInterval, containerWidth: CGFloat) -> some View {
        let h = height(from: interval.start, to: interval.end)
        let usable = max(0, containerWidth - Self.leftGutter - Self.rightPad)
        return RoundedRectangle(cornerRadius: 6)
            .fill(Color.accentColor.opacity(0.18))
            .overlay(RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 1.2))
            .overlay(alignment: .topLeading) {
                label("New entry", timeRange(snap(interval.start), snap(interval.end)),
                      h: h, color: .primary, secondaryTime: true)
            }
            .frame(width: usable, height: h, alignment: .topLeading)
            .position(x: Self.leftGutter + usable / 2, y: yOffset(for: interval.start) + h / 2)
            .allowsHitTesting(false)
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
        let isRunning = entry.end == nil
        let showGrips = hovered == entry.id || dragPreview?.id == entry.id
        let frame = columnFrame(place, containerWidth)
        // A clipped entry's true start is on another day — say so instead of
        // showing a bare "08:47" that reads as today.
        let startText = start < dayInterval.start
            ? Self.dayTimeFormatter.string(from: start) : Self.timeFormatter.string(from: start)
        let timeText = "\(startText)–\(Self.timeFormatter.string(from: end))"

        return RoundedRectangle(cornerRadius: 6)
            .fill(color.gradient)
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
            .overlay(alignment: .topLeading) { label(name, timeText, h: h, color: .white) }
            // The running entry's start is adjustable (top grip); its end is
            // "now" and stays pinned — no bottom grip.
            .overlay(alignment: .top) { if showGrips { resizeHandle(id: entry.id, start: entry.start, end: entry.end ?? Date(), edge: .top, cardHeight: h, onTap: { editing = entry }) } }
            .overlay(alignment: .bottom) { if showGrips && !isRunning { resizeHandle(id: entry.id, start: entry.start, end: entry.end ?? Date(), edge: .bottom, cardHeight: h, onTap: { editing = entry }) } }
            .frame(width: frame.w, height: h, alignment: .topLeading)
            .position(x: frame.x + frame.w / 2, y: yOffset(for: start) + h / 2)
            .onTapGesture { editing = entry }
            // Hovered card above its neighbours: a short entry renders taller
            // than its time span, so the next card can cover its bottom grip.
            .zIndex(showGrips ? 2 : 0)
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
            .overlay(alignment: .top) { if showGrips { resizeHandle(id: block.id, start: block.start, end: block.end, edge: .top, tint: color, cardHeight: h, onTap: { reviewing = block }) } }
            .overlay(alignment: .bottom) { if showGrips { resizeHandle(id: block.id, start: block.start, end: block.end, edge: .bottom, tint: color, cardHeight: h, onTap: { reviewing = block }) } }
            .frame(width: frame.w, height: h, alignment: .topLeading)
            .position(x: frame.x + frame.w / 2, y: yOffset(for: start) + h / 2)
            .onTapGesture { reviewing = block }
            // Ghosts yield to drawing: a drag that starts on one draws a new
            // entry straight over it (the entry then clips/dismisses the
            // ghosts it covers), so a day of slivers never has to be
            // dismissed one by one before you can log what you know you did.
            .gesture(createGesture(minimumDistance: 6))
            .zIndex(showGrips ? 2 : 0)
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
        let py = overlayY(blockTop: yOffset(for: block.start), blockH: blockH,
                          overlayH: max(reviewPanelHeight, 190))

        return ZStack(alignment: .topLeading) {
            Rectangle().fill(.black.opacity(0.2))
                .frame(width: containerWidth, height: Self.hourHeight * 24)
                .contentShape(Rectangle())
                .onTapGesture { reviewing = nil }
            // Placed with padding, not .offset — offset is visual-only, so the
            // scroll anchor (.id) would stay at the content's top-left and
            // scrollTo would jump to the start of the day.
            GhostReviewPanel(block: block, onDone: { reviewing = nil })
                .frame(width: Self.panelWidth)
                .background(GeometryReader { g in
                    Color.clear
                        .onAppear { reviewPanelHeight = g.size.height }
                        .onChange(of: g.size.height) { reviewPanelHeight = $0 }
                })
                .id("review-panel")
                .padding(.leading, px)
                .padding(.top, py)
        }
        .frame(width: containerWidth, height: Self.hourHeight * 24, alignment: .topLeading)
    }

    /// Below the block when it fits, above it otherwise — a panel for a block
    /// near the end of the day used to open past the content bottom, half
    /// hidden. Clamped to the day content as a last resort.
    private func overlayY(blockTop: CGFloat, blockH: CGFloat, overlayH: CGFloat) -> CGFloat {
        let contentH = Self.hourHeight * 24
        let below = blockTop + blockH + 6
        if below + overlayH <= contentH { return below }
        return max(0, min(blockTop - overlayH - 6, contentH - overlayH))
    }

    /// A non-interactive hovercard with the full evidence, shown while hovering
    /// a ghost card (the icons give the glance; this gives the detail).
    private func hovercard(_ block: ProvisionalBlock, places: [String: Placement], containerWidth: CGFloat) -> some View {
        let place = places[Item.block(block).id] ?? Placement(column: 0, columns: 1)
        let frame = columnFrame(place, containerWidth)
        let blockH = height(from: block.start, to: block.end)
        let cardW: CGFloat = 260
        let px = min(max(Self.leftGutter, frame.x), max(Self.leftGutter, containerWidth - cardW - 10))
        let py = overlayY(blockTop: yOffset(for: block.start), blockH: blockH,
                          overlayH: max(hovercardHeight, 60))

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
            .background(GeometryReader { g in
                Color.clear
                    .onAppear { hovercardHeight = g.size.height }
                    .onChange(of: g.size.height) { hovercardHeight = $0 }
            })
            .offset(x: px, y: py)
        }
        .frame(width: containerWidth, height: Self.hourHeight * 24, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    // MARK: - Resize (entries and ghost blocks alike)

    private enum ResizeEdge { case top, bottom }

    /// Grip zones shrink to a third of the card on short blocks so a 15-min
    /// block keeps a clickable middle; they'd otherwise cover it entirely.
    private static func gripZoneHeight(cardHeight: CGFloat) -> CGFloat {
        min(handleHeight, max(4, cardHeight / 3))
    }

    private func resizeHandle(id: UUID, start: Date, end: Date, edge: ResizeEdge,
                              tint: Color = .white, cardHeight: CGFloat,
                              onTap: @escaping () -> Void) -> some View {
        Rectangle()
            .fill(Color.white.opacity(0.001))
            .frame(height: Self.gripZoneHeight(cardHeight: cardHeight))
            // Outline + shadow so the capsule reads on any project colour —
            // plain white was invisible on the bright ones.
            .overlay(
                Capsule().fill(tint.opacity(0.95))
                    .frame(width: 26, height: 3.5)
                    .overlay(Capsule().strokeBorder(.black.opacity(0.35), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.5), radius: 1, y: 0.5)
            )
            .contentShape(Rectangle())
            .highPriorityGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        isResizing = true
                        updateDrag(id: id, start: start, end: end, edge: edge, translationY: value.translation.height)
                    }
                    .onEnded { value in
                        isResizing = false
                        // A click that never moved is the card tap, not a
                        // resize — committing it would snap-shift an edge
                        // that wasn't on the 5-minute grid.
                        if abs(value.translation.height) < 4 && abs(value.translation.width) < 4 {
                            dragPreview = nil
                            dragEdge = nil
                            onTap()
                        } else {
                            commitDrag()
                        }
                    }
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
            entry.start = s
            // A running entry has no end — only its start moved; writing the
            // preview's snapshot end would silently stop the timer.
            if entry.end != nil { entry.end = e }
            state.saveResizedEntry(entry)
        } else if var block = blocks.first(where: { $0.id == p.id }) {
            block.start = s; block.end = e; state.saveResizedBlock(block)
        }
    }

    private func snap(_ date: Date) -> Date {
        let t = date.timeIntervalSinceReferenceDate
        return Date(timeIntervalSinceReferenceDate: (t / Self.snapSeconds).rounded() * Self.snapSeconds)
    }

    /// Clamp an edge at the nearest neighbour so a resize can never create an
    /// overlap. A ghost stops at entries and other ghosts; an entry stops only
    /// at other entries and may sweep over ghosts, which `clearRange` then
    /// clips or dismisses. Edges normally stop at the displayed day, but
    /// an entry that already crosses the boundary keeps its true edge draggable
    /// (the old day-edge clamp made grabbing a clipped entry's grip snap its
    /// multi-day start to the day's start hour). Neighbours are fetched from
    /// the store over a padded window, since `entries` only covers this day.
    private func neighborBounds(excluding id: UUID, start: Date, end: Date) -> (lower: Date, upper: Date) {
        var lower = start < dayInterval.start ? Date.distantPast : dayInterval.start
        var upper = end > dayInterval.end ? Date.distantFuture : dayInterval.end
        func consider(_ oid: UUID, _ s: Date, _ e: Date) {
            guard oid != id else { return }
            if e <= start { lower = max(lower, e) }
            if s >= end { upper = min(upper, s) }
        }
        let pad: TimeInterval = 86_400
        let window = DateInterval(start: start.addingTimeInterval(-pad),
                                  end: end.addingTimeInterval(pad))
        for e in (try? state.store.entries(in: window)) ?? [] { consider(e.id, e.start, e.end ?? Date()) }
        let resizingEntry = entries.contains { $0.id == id }
        if !resizingEntry {
            for b in state.pendingBlocks where b.end > b.start { consider(b.id, b.start, b.end) }
        }
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

/// Reports mouse position over the timeline content in the content's own
/// coordinates. AppKit converts through the scroll offset correctly, unlike
/// SwiftUI's .onHover tracking areas, which go stale inside a ScrollView.
/// Never intercepts clicks or scrolls (hitTest nil).
private struct MouseTrackingView: NSViewRepresentable {
    var onMove: (CGPoint?) -> Void

    func makeNSView(context: Context) -> Tracker { Tracker(onMove: onMove) }
    func updateNSView(_ view: Tracker, context: Context) { view.onMove = onMove }

    final class Tracker: NSView {
        var onMove: (CGPoint?) -> Void

        init(onMove: @escaping (CGPoint?) -> Void) {
            self.onMove = onMove
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("unused") }

        override var isFlipped: Bool { true }   // match SwiftUI's top-left origin

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(
                rect: .zero,
                options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self, userInfo: nil))
        }

        override func mouseMoved(with event: NSEvent) {
            onMove(convert(event.locationInWindow, from: nil))
        }
        override func mouseExited(with event: NSEvent) { onMove(nil) }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
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
    let end: Date?

    init(date: Date, end: Date? = nil) {
        self.date = date
        self.end = end
        self.id = date.timeIntervalSince1970
    }
}
