import AgentManagerCore
import SwiftUI

/// Logs an already-added agent in. Login happens in a real Terminal (so the
/// browser sign-in and any code Claude asks you to paste back just work), then
/// we verify identity and flip the status to Connected.
struct LoginSheet: View {
    @Bindable var model: AppModel
    let account: Account
    @Environment(\.dismiss) private var dismiss

    private var live: Account { model.accounts.first(where: { $0.id == account.id }) ?? account }
    private var isBusy: Bool { model.busyAccountIDs.contains(account.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Log in — \(account.label)").font(.title3.bold())

            VStack(alignment: .leading, spacing: 10) {
                step(1, "Open Terminal as this account.")
                step(2, "Complete the browser sign-in. If Claude shows a code, paste it back into that Terminal window.")
                step(3, "Come back and verify.")
            }
            .font(.system(size: 13))

            HStack(spacing: 5) {
                Image(systemName: live.status.systemImage)
                Text(live.status.displayName)
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(live.status.tint)

            Divider()

            HStack {
                Button {
                    model.loginInTerminal(account)
                } label: {
                    Label("Open Terminal to log in", systemImage: "terminal")
                }
                .buttonStyle(.borderedProminent)

                Button {
                    model.verify(account)
                } label: {
                    if isBusy {
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Verifying…") }
                    } else {
                        Label("Verify connection", systemImage: "checkmark.shield")
                    }
                }
                .disabled(isBusy)

                Spacer()
                Button(live.status == .connected ? "Done" : "Close") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onChange(of: live.status) { _, new in
            if new == .connected { dismiss() }
        }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(n).").foregroundStyle(.secondary).monospacedDigit()
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}
