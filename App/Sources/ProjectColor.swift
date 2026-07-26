import SwiftUI
import ClocktopusCore

extension SignalKind {
    /// SF Symbol used to represent this signal on a ghost card.
    var symbolName: String {
        switch self {
        case .terminal: return "terminal"
        case .tmux: return "squares.below.rectangle"
        case .aiTool: return "sparkles"
        case .browser: return "globe"
        case .app: return "macwindow"
        }
    }
}

extension AppState {
    /// A distinct colour per project (by its position in the list) so entries
    /// are easy to tell apart in the timeline and lists.
    static let projectPalette: [Color] = [
        .blue, .green, .orange, .purple, .pink, .teal, .indigo, .brown, .red, .cyan,
    ]

    func color(for projectId: String) -> Color {
        guard let index = projects.firstIndex(where: { $0.id == projectId }) else { return .gray }
        return Self.projectPalette[index % Self.projectPalette.count]
    }
}
