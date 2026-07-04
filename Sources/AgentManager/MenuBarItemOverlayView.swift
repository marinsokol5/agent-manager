import AppKit

/// Paints the status-item image at full, un-dimmed color on top of the button.
///
/// macOS renders an `NSStatusBarButton`'s own template image through its cell, and the
/// window server dims that cell on the menu bar of an *inactive* display (the washed-out
/// look on a secondary screen). A plain `NSView` subview, by contrast, is drawn with the
/// colors we pick and is not subject to that dimming. Painting the same image here keeps
/// the item fully colored on every screen — the approach Stats (stats-bar) uses for its
/// menu-bar widgets.
///
/// The underlying `button.image` is left in place (as a transparent placeholder) so the
/// status item keeps auto-sizing itself; on the active display the two renderings are
/// identical, so the overlay is invisible there.
final class MenuBarItemOverlayView: NSView {
    var image: NSImage? {
        didSet {
            guard self.image !== oldValue else { return }
            self.needsDisplay = true
        }
    }

    // Purely decorative: let clicks fall through to the status button so its popover opens.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let image else { return }
        let size = image.size
        guard size.width > 0, size.height > 0 else { return }

        let rect = NSRect(
            x: ((self.bounds.width - size.width) / 2).rounded(),
            y: ((self.bounds.height - size.height) / 2).rounded(),
            width: size.width,
            height: size.height)

        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)

        // Template images are alpha masks; tint them to the dynamic label color so the
        // result matches what the system would draw on an active display (light/dark aware)
        // without inheriting the inactive-menu-bar dimming. Non-template images (e.g. colored
        // brand logos) are already colored, so leave them as-is.
        if image.isTemplate {
            NSColor.labelColor.set()
            rect.fill(using: .sourceAtop)
        }
    }
}
