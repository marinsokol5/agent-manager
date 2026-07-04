import AgentManagerCore
import SwiftUI

/// "Add new agent" — just creates the agent (managed home + symlink farm),
/// persisted logged-out. Logging in is a separate step on the row, so an
/// interrupted login never loses the agent.
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
                labeled("Color") { ColorField(hex: $colorHex) }

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
                Button("Add agent") { submit() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(label.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
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
