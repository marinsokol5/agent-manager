import SwiftUI

// MARK: - AMButtonStyle

/// The app's one button vocabulary, built on `Theme` tokens. Apply with
/// `.buttonStyle(.am(.primary))` and keep the label as the button's content — the
/// style owns the chrome (fill, border, padding, hover, pressed, disabled) so every
/// button reads the same way. Replaces the hand-rolled rounded-rectangle buttons
/// scattered across the views.
struct AMButtonStyle: ButtonStyle {
    enum Variant {
        /// Filled accent — the one primary action on a surface.
        case primary
        /// Subtle filled surface with a hairline — secondary actions.
        case secondary
        /// Outlined in `danger` — destructive actions.
        case destructive
        /// Text-only until hovered — low-emphasis / inline actions.
        case ghost
    }

    enum Size { case regular, large }

    var variant: Variant = .primary
    var size: Size = .regular

    func makeBody(configuration: Configuration) -> some View {
        StyledButton(configuration: configuration, variant: variant, size: size)
    }

    private struct StyledButton: View {
        let configuration: Configuration
        let variant: Variant
        let size: Size

        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(font)
                .foregroundStyle(foreground)
                .padding(.horizontal, hPadding)
                .padding(.vertical, vPadding)
                .frame(maxWidth: fillsWidth ? .infinity : nil)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.md)
                        .fill(fill))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.md)
                        .strokeBorder(border, lineWidth: 1))
                .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
                .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.45)
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
        }

        private var fillsWidth: Bool { size == .large }

        private var font: Font {
            size == .large ? Theme.Font.heading : Theme.Font.callout.weight(.semibold)
        }

        private var hPadding: CGFloat { size == .large ? Theme.Spacing.lg : Theme.Spacing.md }
        private var vPadding: CGFloat { size == .large ? 11 : 7 }

        private var foreground: Color {
            switch variant {
            case .primary: return .white
            case .secondary, .ghost: return .primary
            case .destructive: return Theme.danger
            }
        }

        private var fill: Color {
            switch variant {
            case .primary:
                return Theme.accent.opacity(hovering ? 0.9 : 1)
            case .secondary:
                return Color.primary.opacity(hovering ? 0.1 : 0.06)
            case .ghost:
                return Color.primary.opacity(hovering ? 0.06 : 0)
            case .destructive:
                return Theme.danger.opacity(hovering ? 0.1 : 0)
            }
        }

        private var border: Color {
            switch variant {
            case .primary, .ghost: return .clear
            case .secondary: return Color.primary.opacity(0.1)
            case .destructive: return Theme.danger.opacity(0.35)
            }
        }
    }
}

extension ButtonStyle where Self == AMButtonStyle {
    /// `.buttonStyle(.am(.primary))` — see `AMButtonStyle`.
    static func am(_ variant: AMButtonStyle.Variant = .primary,
                   size: AMButtonStyle.Size = .regular) -> AMButtonStyle {
        AMButtonStyle(variant: variant, size: size)
    }
}

// MARK: - AMBadge

/// A small capsule pill: optional icon (or a spinner) + text, tinted by role.
/// `prominent` fills with the tint; otherwise it's a soft tinted chip. Replaces the
/// repeated status / provider / percent / count pills across the views.
struct AMBadge: View {
    let text: String
    var systemImage: String? = nil
    var tint: Color = Theme.neutral
    var prominent: Bool = false
    /// Swap the leading icon for a small spinner (e.g. an account mid-ping).
    var loading: Bool = false

    var body: some View {
        HStack(spacing: 5) {
            if loading {
                ProgressView().controlSize(.small)
            } else if let systemImage {
                Image(systemName: systemImage).font(.system(size: 11))
            }
            Text(text).font(Theme.Font.caption.weight(.medium))
        }
        .foregroundStyle(prominent ? Color.white : tint)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Capsule().fill(prominent ? tint : tint.opacity(0.12)))
    }
}

// MARK: - Surfaces & hover

extension View {
    /// A rounded, hairline-bordered surface — the app's card chrome. Pass the
    /// owner's `hovering` to get the subtle raise the account rows use; leave it
    /// `false` for static cards (job rows, log rows).
    func amCard(radius: CGFloat = Theme.Radius.md,
                hovering: Bool = false,
                bordered: Bool = true) -> some View {
        background(
            RoundedRectangle(cornerRadius: radius)
                .fill(Color.primary.opacity(hovering ? 0.05 : 0.035)))
        .overlay(
            RoundedRectangle(cornerRadius: radius)
                .strokeBorder(Color.primary.opacity(bordered ? 0.08 : 0)))
    }
}
