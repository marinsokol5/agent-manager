import SwiftUI

/// Top-level shell: fixed sidebar + a detail pane that switches on the route.
struct RootView: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            SidebarView(model: model)
            Divider()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 760, minHeight: 480)
    }

    @ViewBuilder
    private var detail: some View {
        switch model.route {
        case .agents:
            AgentsView(model: model)
        case .planner:
            PlannerView(model: model)
        case .monitoring:
            MonitoringView(model: model)
        case .preferences:
            PreferencesView(model: model)
        }
    }
}

/// A simple centered placeholder for routes that aren't built yet.
struct PlaceholderView: View {
    let title: String
    let systemImage: String
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 38))
                .foregroundStyle(.tertiary)
            Text(title).font(.title2.bold())
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
