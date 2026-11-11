import AgentManagerCore
import SwiftUI

/// "Add new agent" — just creates the agent (managed home + symlink farm),
/// persisted logged-out. Logging in is a separate step on the row, so an
/// interrupted login never loses the agent. With "Your default login" picked
/// instead, nothing is provisioned and no login runs: the provider's default
/// login is verified and the agent is saved connected, with that login as its
/// home (`DefaultLoginAccounts.add`).
struct AddAccountSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var label = ""
    @State private var idText = ""
    @State private var provider: Provider = .claude
    @State private var colorHex = Theme.palette[2]
    @State private var sourceOverride = ""
    @State private var showAdvanced = false
    @State private var errorText: String?
    @State private var loginSource: AccountLoginSource = .managed
    @State private var submitting = false

    /// The account already tracking this provider's default login, if any —
    /// the option is then disabled (one per provider, enforced in Core too).
    private var defaultOwner: Account? { model.defaultLoginOwner(for: provider) }

    /// User-typed id, or one auto-derived from the label.
    private var effectiveID: String {
        let trimmed = idText.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? model.suggestedID(for: label) : trimmed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add agent").font(.title3.bold())

            VStack(alignment: .leading, spacing: 12) {
                labeled("Label") {
                    TextField("e.g. Claude (work)", text: $label)
                        .textFieldStyle(.roundedBorder)
                }
                labeled("ID") {
                    TextField(model.suggestedID(for: label), text: $idText)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                }
                labeled("Provider") {
                    Picker("", selection: $provider) {
                        ForEach(Provider.allCases, id: \.self) { provider in
                            Text(provider.displayName).tag(provider)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
                labeled("Login") {
                    LoginSourcePicker(selection: $loginSource, provider: provider, defaultOwner: defaultOwner)
                }
                labeled("Color") { ColorField(hex: $colorHex) }

                // Source home only matters for a managed home (its symlink farm).
                if loginSource == .managed {
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { showAdvanced.toggle() }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .semibold))
                                .rotationEffect(.degrees(showAdvanced ? 90 : 0))
                            Text("Advanced")
                        }
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if showAdvanced {
                        labeled("Source home") {
                            VStack(alignment: .leading, spacing: 4) {
                                TextField(provider.defaultSourceHome(homeDirectory: FileManager.default.homeDirectoryForCurrentUser).path, text: $sourceOverride)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(.callout, design: .monospaced))
                                Text("Everything is symlinked from here; only \(Text(provider.identityFileName).font(.system(.caption, design: .monospaced))) stays independent and per-account.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }

            if let errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                if submitting { ProgressView().controlSize(.small) }
                Button("Add agent") { submit() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(label.trimmingCharacters(in: .whitespaces).isEmpty || submitting)
            }
        }
        .padding(20)
        .frame(width: 460)
        // A provider whose default login is taken can't keep that choice.
        .onChange(of: provider) { _, _ in
            if defaultOwner != nil { loginSource = .managed }
        }
    }

    private func labeled<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .frame(width: 72, alignment: .leading)
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func submit() {
        if loginSource == .providerDefault {
            submitting = true
            errorText = nil
            Task {
                let error = await model.addDefaultLoginAccount(
                    label: label.trimmingCharacters(in: .whitespaces),
                    id: effectiveID,
                    color: colorHex,
                    provider: provider)
                submitting = false
                if let error { errorText = error } else { dismiss() }
            }
            return
        }
        let source: URL? = {
            let trimmed = sourceOverride.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }
            return URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath, isDirectory: true)
        }()
        if let error = model.addAccount(
            label: label.trimmingCharacters(in: .whitespaces),
            id: effectiveID,
            color: colorHex,
            provider: provider,
            source: source)
        {
            errorText = error
        } else {
            dismiss()
        }
    }
}

/// The add/edit sheets' "Login" choice: the account's own managed home, or the
/// provider's default login as its home. The default option is disabled (with
/// the reason under it) while another account already uses it.
struct LoginSourcePicker: View {
    @Binding var selection: AccountLoginSource
    let provider: Provider
    /// Another account that already tracks this provider's default login.
    let defaultOwner: Account?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("", selection: $selection) {
                Text("Managed home (isolated login)").tag(AccountLoginSource.managed)
                Text("Your default login").tag(AccountLoginSource.providerDefault)
                    .selectionDisabled(defaultOwner != nil)
            }
            .labelsHidden()
            .pickerStyle(.radioGroup)
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var caption: String {
        if let defaultOwner {
            return "“\(defaultOwner.label)” already uses your default \(provider.displayName) login — only one account per provider can."
        }
        switch selection {
        case .managed:
            return "Its own isolated home and login."
        case .providerDefault:
            return "The login \(provider.defaultLoginClients) uses — runs, pings, and scheduling work as usual, without an isolated home. Agent Manager never writes to its files itself."
        }
    }
}
