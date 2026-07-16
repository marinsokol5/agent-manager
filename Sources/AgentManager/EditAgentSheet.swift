import AgentManagerCore
import SwiftUI

/// Edit an existing agent's label and color (its id and home are fixed).
struct EditAgentSheet: View {
    @Bindable var model: AppModel
    let account: Account
    @Environment(\.dismiss) private var dismiss

    @State private var label: String
    @State private var colorHex: String
    /// `-1` = use app default (1 min); `0` = manual only; else interval seconds.
    @State private var refreshSeconds: Int

    init(model: AppModel, account: Account) {
        self.model = model
        self.account = account
        _label = State(initialValue: account.label)
        _colorHex = State(initialValue: account.color)
        _refreshSeconds = State(initialValue: account.usageRefreshSeconds ?? -1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit agent").font(.title3.bold())

            VStack(alignment: .leading, spacing: 12) {
                row("Label") {
                    TextField("Label", text: $label).textFieldStyle(.roundedBorder)
                }
                row("ID") {
                    Text(account.id).font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
                }
                row("Color") { ColorField(hex: $colorHex) }
                row("Usage refresh") {
                    Picker("Usage refresh", selection: $refreshSeconds) {
                        Text("Default (1 min)").tag(-1)
                        Text("1 minute").tag(60)
                        Text("2 minutes").tag(120)
                        Text("5 minutes").tag(300)
                        Text("15 minutes").tag(900)
                        Text("30 minutes").tag(1800)
                        Text("Manual only").tag(0)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    model.updateAccount(
                        account,
                        label: label.trimmingCharacters(in: .whitespaces),
                        color: colorHex,
                        usageRefreshSeconds: refreshSeconds == -1 ? nil : refreshSeconds)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(label.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func row<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title).frame(width: 72, alignment: .leading).foregroundStyle(.secondary)
            content()
        }
    }
}
