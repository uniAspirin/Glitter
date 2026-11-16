// Xcode supplies macro plugins; the standalone swiftc build keeps its existing path.
#if XCODE_BUILD && DEBUG
import SwiftUI

private enum PreviewScenario {
    case today, month, collapsed, empty, longTitle
}

@MainActor
private struct PanelPreview: View {
    @StateObject private var store: TaskStore
    @StateObject private var state: PanelState

    init(_ scenario: PreviewScenario) {
        let store = TaskStore(defaults: DemoDefaults())
        switch scenario {
        case .empty: store.loadEmptyListDemoData()
        case .longTitle: store.loadLongTitleDemoData()
        default: store.loadDemoData()
        }
        let geometry = NotchGeometry(
            screenFrame: NSRect(x: 0, y: 0, width: 1512, height: 982),
            hasNotch: true, notchHeight: 32, notchWidth: 180,
            displayScale: 2, rows: store.monthRows.count
        )
        let state = PanelState(geometry: geometry)
        state.expanded = scenario != .collapsed
        state.geometry.showingMonth = scenario == .month
        Self.updateGeometry(store: store, state: state)
        state.onSelectDay = { [weak store, weak state] in
            guard let store, let state else { return }
            state.geometry.showingMonth = false
            Self.updateGeometry(store: store, state: state)
        }
        state.onSelectMonth = { [weak store, weak state] in
            guard let store, let state else { return }
            state.geometry.showingMonth = true
            Self.updateGeometry(store: store, state: state)
        }
        state.onTogglePinned = { [weak state] in state?.pinned.toggle() }
        _store = StateObject(wrappedValue: store)
        _state = StateObject(wrappedValue: state)
    }

    private static func updateGeometry(store: TaskStore, state: PanelState) {
        var geometry = state.geometry
        geometry.showsCalendar = store.hasStatistics
        geometry.noticeHeight = store.panelNotice.map {
            $0.height(width: geometry.contentWidth, compact: true) + geometry.padding
        } ?? 0
        if store.hasStatistics && !store.todayTasks.isEmpty {
            geometry.measureToday(tasks: store.presentationTasks, error: nil, summary: store.presentationSummary)
        } else {
            geometry.measureMessage(store.panelMessage)
        }
        state.geometry = geometry
        state.present(size: geometry.rect(expanded: state.expanded).size,
                      expansion: state.expanded ? 1 : 0,
                      month: geometry.showingMonth ? 1 : 0)
    }

    var body: some View {
        ZStack(alignment: .top) {
            NotchPanelView(store: store, state: state)
            PanelHeaderView(store: store, state: state)
                .frame(height: state.geometry.collapsedHeight)
        }
        .frame(width: state.presentationSize.width, height: state.presentationSize.height)
        .clipShape(UnevenRoundedRectangle(
            bottomLeadingRadius: state.cornerRadius,
            bottomTrailingRadius: state.cornerRadius
        ))
        .preferredColorScheme(.dark)
        .padding(24)
        .background(Color.gray.opacity(0.25))
        .onChange(of: store.todayTasks) {
            Self.updateGeometry(store: store, state: state)
        }
    }
}

#Preview("Today · Sample Tasks", traits: .sizeThatFitsLayout) {
    PanelPreview(.today)
}

#Preview("Month · Sample History", traits: .sizeThatFitsLayout) {
    PanelPreview(.month)
}

#Preview("Collapsed · Notched Display", traits: .sizeThatFitsLayout) {
    PanelPreview(.collapsed)
}

#Preview("Empty List", traits: .sizeThatFitsLayout) {
    PanelPreview(.empty)
}

#Preview("Long Task · Scrolling", traits: .sizeThatFitsLayout) {
    PanelPreview(.longTitle)
}
#endif
