import AgentManagerCore
import SwiftUI

/// The Agents route: add new agents, see existing ones with their connection
/// status, and act on them (ping, launch, verify, reconcile, remove).
struct AgentsView: View {
    @Bindable var model: AppModel
    @State private var showingAdd = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if model.accounts.isEmpty {
                emptyState
            } else {
                addButton
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(Array(model.accounts.enumerated()), id: \.element.id) { index, account in
                                AccountRowView(model: model, account: account, index: index, total: model.accounts.count)
                                    .id(account.id)
                            }
                        }
                        .padding(.bottom, 4)
                    }
                    .onAppear { scrollToPending(proxy) }
                    .onChange(of: model.revealTick) { scrollToPending(proxy) }
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
        .sheet(isPresented: $showingAdd) {
            AddAccountSheet(model: model)
        }
    }

    /// Scroll to the agent a reveal asked for (e.g. the sidebar recommendation
    /// card), then clear the request. A small delay lets the route switch / accordion
    /// expansion settle so the lazy row exists before we scroll to it.
    private func scrollToPending(_ proxy: ScrollViewProxy) {
        guard let id = model.pendingRevealAgentID else { return }
        model.pendingRevealAgentID = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            withAnimation(.snappy(duration: 0.3)) {
                proxy.scrollTo(id, anchor: .top)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Agents").font(Theme.Font.screenTitle)
            Text("Ranked by priority — token windows fill #1 first, then #2, then #3. Reorder with the arrows. Each agent is an isolated, independently-anchored account with its own config home.")
                .font(Theme.Font.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var addButton: some View {
        Button {
            showingAdd = true
        } label: {
            Label("Add new agent", systemImage: "plus")
                .font(.system(size: 15, weight: .semibold))
                .padding(.vertical, 4)
        }
        .controlSize(.large)
        .buttonStyle(.borderedProminent)
    }

    private var emptyState: some View {
        VStack(spacing: 18) {
            VStack(spacing: 10) {
                Image(systemName: "person.2.badge.plus")
                    .font(.system(size: 40))
                    .foregroundStyle(.tertiary)
                Text("No agents yet")
                    .font(.headline)
                Text("Add one to create an isolated, managed home and log in as that account.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }

            // The first-run trust moment, right before you hand over an OAuth login.
            VStack(alignment: .leading, spacing: 12) {
                trustPoint("lock.shield", "Local-only",
                           "Tokens never leave this Mac. No backend, no cloud, no telemetry.")
                trustPoint("arrow.triangle.branch", "Isolated",
                           "Each agent gets its own config home — your default Claude / Codex login is never touched or swapped.")
                trustPoint("list.bullet.rectangle.portrait", "Auditable",
                           "Every read, ping, and launch is recorded in Monitoring. Nothing hidden, no secrets logged.")
            }
            .padding(16)
            .frame(maxWidth: 440)
            .amCard(radius: Theme.Radius.md)

            addButton
                .controlSize(.extraLarge)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func trustPoint(_ icon: String, _ title: String, _ body: String) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundStyle(Theme.accent)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12.5, weight: .semibold))
                Text(body)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
