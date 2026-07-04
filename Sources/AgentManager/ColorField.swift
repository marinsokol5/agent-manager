import SwiftUI

/// Color chooser: the default palette swatches plus a `#hex` field for anything
/// custom. Avoids the floating system color panel (which doesn't dismiss with
/// the sheet); everything lives inline.
struct ColorField: View {
    @Binding var hex: String

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Theme.palette, id: \.self) { swatch in
                Circle()
                    .fill(Color(hex: swatch))
                    .frame(width: 20, height: 20)
                    .overlay(Circle().strokeBorder(Color.primary, lineWidth: hex.lowercased() == swatch.lowercased() ? 2 : 0))
                    .onTapGesture { hex = swatch }
            }
            Divider().frame(height: 18)
            Circle()
                .fill(Color(hex: hex))
                .frame(width: 20, height: 20)
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.25)))
            TextField("#RRGGBB", text: $hex)
                .textFieldStyle(.roundedBorder)
                .font(.system(.callout, design: .monospaced))
                .frame(width: 90)
            Spacer()
        }
    }
}
