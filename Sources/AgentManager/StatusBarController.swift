import AgentManagerCore
import AppKit
import Observation
import SwiftUI

/// Owns the live `NSStatusItem`(s) and keeps them in sync with `AppModel`.
///
/// SwiftUI's `MenuBarExtra` can't vend a *dynamic* number of menu-bar items, so
/// the "Individual" mode (one item per agent) needs AppKit. We watch the model
/// via `withObservationTracking` and rebuild the item set when the mode or the
/// agent list changes, refreshing each item's rendered icon when usage updates.
/// Each item opens a SwiftUI popover anchored to its button.
@MainActor
final class StatusBarController {
    private let model: AppModel
    private let popover = NSPopover()

    /// Live items paired with the account id they represent (`nil` = the merged
    /// summary item, or the placeholder when nothing is connected).
    private var entries: [(item: NSStatusItem, accountID: String?)] = []
    /// Maps a status button back to its account id (`""` = merged/placeholder).
    private var buttonAccount: [ObjectIdentifier: String] = [:]
    /// The structural fingerprint of the current item set; a change forces a
    /// rebuild, otherwise we only re-render icons (cheap, no menu-bar flicker).
    private var signature = ""
    /// The button whose popover is currently open (for click-to-toggle).
    private weak var openButton: NSStatusBarButton?
    /// Global mouse-down monitor that dismisses the popover on outside clicks —
    /// `.transient` can't, since we don't activate the app (the popover stays in
    /// the background and never sees those clicks). Installed while shown.
    private var clickMonitor: Any?
    init(model: AppModel) {
        self.model = model
        popover.behavior = .transient
        // No open/close animation — it reads as lag for a menu-bar popover.
        popover.animates = false
        // While the app's theme overrides `NSApp.appearance`, the status buttons
        // are pinned to the *system* appearance instead (see `applyAppearance`) —
        // so a system light/dark flip must re-pin them by hand. The observer is
        // never detached: this controller lives for the app's lifetime (same
        // stance as AppModel's presence observers).
        _ = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.applyAppearance() }
        }
        startObserving()
    }

    // MARK: - Observation

    /// Re-arming Observation loop: `render()` reads the model properties we care
    /// about, so any change to them fires `onChange`, where we re-arm and redraw.
    private func startObserving() {
        withObservationTracking { [weak self] in
            self?.render()
        } onChange: { [weak self] in
            Task { @MainActor in self?.startObserving() }
        }
    }

    private func render() {
        let mode = model.menuBarMode
        let accounts = model.menuBarAccounts
        // Merged is a single static item, so its set never changes; only the
        // individual mode's item set tracks the agent list.
        let newSignature: String
        switch mode {
        case .hidden: newSignature = "hidden"
        case .merged: newSignature = "merged"
        case .individual: newSignature = "individual|" + accounts.map(\.id).joined(separator: ",")
        }
        if newSignature != signature {
            rebuild(mode: mode, accounts: accounts)
            signature = newSignature
        }
        refreshIcons()
        applyAppearance()
    }

    /// Keeps the menu-bar surfaces on the right side of the app's theme override.
    ///
    /// The status buttons belong to the *menu bar*, not the app: their template
    /// glyphs and the overlay's `labelColor` must resolve against what the menu
    /// bar actually looks like, or a dark-themed app on a light menu bar draws
    /// white-on-white. While a theme override is active they're pinned to the
    /// real system appearance (`NSApp.effectiveAppearance` is no use here — it
    /// reflects the override); with no override, nil/inherit is already right.
    ///
    /// The popover, by contrast, is the app's own surface and follows the theme.
    /// For `.system` its nil appearance derives from the anchor button — the
    /// system appearance — which is exactly what we want.
    private func applyAppearance() {
        let pin = model.theme == .system ? nil : Self.systemAppearance()
        for entry in entries { entry.item.button?.appearance = pin }
        popover.appearance = model.theme.nsAppearance
    }

    /// The true system appearance — what the menu bar renders with — read from
    /// the global defaults domain (`AppleInterfaceStyle` is "Dark" in dark mode
    /// and absent in light mode).
    private static func systemAppearance() -> NSAppearance? {
        let dark = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
        return NSAppearance(named: dark ? .darkAqua : .aqua)
    }

    // MARK: - Item lifecycle

    private func rebuild(mode: AppModel.MenuBarMode, accounts: [Account]) {
        for entry in entries { NSStatusBar.system.removeStatusItem(entry.item) }
        entries.removeAll()
        buttonAccount.removeAll()
        dismiss()

        switch mode {
        case .hidden:
            break
        case .merged:
            entries.append((makeItem(), nil))
        case .individual:
            if accounts.isEmpty {
                entries.append((makeItem(), nil))
            } else {
                // macOS inserts each new status item at the leftmost slot, so
                // create them in reverse to get left-to-right = agents order.
                for account in accounts.reversed() { entries.append((makeItem(), account.id)) }
            }
        }

        for entry in entries where entry.item.button != nil {
            buttonAccount[ObjectIdentifier(entry.item.button!)] = entry.accountID ?? ""
        }
    }

    private func makeItem() -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.imagePosition = .imageOnly
        }
        return item
    }

    // MARK: - Icons

    private func refreshIcons() {
        for entry in entries {
            guard let button = entry.item.button else { continue }
            if let id = entry.accountID, let account = model.accounts.first(where: { $0.id == id }) {
                // Expiry-aware: once the 5h window has reset, show a full window
                // (100%) rather than the finished window's stale figure.
                let percent = model.usageReadings[id]?.effectivePrimaryRemainingPercent()
                setButtonImage(
                    Self.brandPercentImage(brand: brandGlyph(for: account.provider), percent: percent),
                    for: button)
            } else {
                // Merged (and the empty-state fallback) shows just the agents
                // glyph — the per-agent detail lives in the dropdown, so the bar
                // stays compact.
                if let icon = Self.agentsIcon() { setButtonImage(icon, for: button) }
            }
        }
    }

    /// Sets the button's rendered image via an always-colored overlay subview that stays
    /// fully colored on the menu bar of an *inactive* display, where macOS dims the
    /// button's own template image. See `MenuBarItemOverlayView`; this matches what Stats
    /// does for its widgets.
    private func setButtonImage(_ image: NSImage, for button: NSStatusBarButton) {
        overlayView(for: button).image = image
        // The button keeps a *transparent* image of the same size purely so the status item
        // auto-sizes its width as before. Drawing the real image here too would double-draw
        // it under the overlay and, with sub-pixel misalignment, visibly fatten the glyphs.
        if button.image?.size != image.size {
            button.image = Self.transparentPlaceholder(size: image.size)
        }
    }

    /// A blank image used only to drive the status item's auto-sizing; see `setButtonImage`.
    private static func transparentPlaceholder(size: NSSize) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.clear.set()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    /// Returns the always-colored overlay for `button`, creating and attaching it on first use.
    private func overlayView(for button: NSStatusBarButton) -> MenuBarItemOverlayView {
        if let existing = button.subviews.lazy.compactMap({ $0 as? MenuBarItemOverlayView }).first {
            return existing
        }
        let overlay = MenuBarItemOverlayView(frame: button.bounds)
        overlay.autoresizingMask = [.width, .height]
        button.addSubview(overlay)
        return overlay
    }

    /// The provider's brand glyph as a template image (SF Symbol fallback).
    private func brandGlyph(for provider: Provider) -> NSImage {
        if let image = ProviderBrandIcon.image(for: provider) { return image }
        let image = NSImage(
            systemSymbolName: ProviderBrandIcon.fallbackSymbol(for: provider),
            accessibilityDescription: provider.displayName) ?? NSImage()
        image.isTemplate = true
        return image
    }

    /// The brand mark shown in merged mode / empty state — the staggered-windows
    /// glyph, as a template the menu bar tints (replaces the generic person.2.fill).
    private static func agentsIcon() -> NSImage? {
        AgentManagerLogo.menuBarGlyph(pointSize: 15)
    }

    /// Bake the brand glyph above the session % into one crisp template image.
    /// The menu bar is only ~22pt tall, so AppKit's
    /// `.imageAbove` overlaps the two — drawing them ourselves (glyph pinned top,
    /// % flush bottom, in black so the template mask keeps full alpha) lets the
    /// system tint it bright white and keeps both crisp.
    private static func brandPercentImage(brand: NSImage, percent: Int?) -> NSImage {
        let height = NSStatusBar.system.thickness // typically 22pt
        let glyphSize: CGFloat = 11

        guard let percent else {
            // No reading yet — center the glyph on its own.
            let image = NSImage(size: NSSize(width: glyphSize + 2, height: height))
            image.lockFocus()
            brand.draw(
                in: NSRect(x: 1, y: (height - glyphSize) / 2, width: glyphSize, height: glyphSize),
                from: .zero, operation: .sourceOver, fraction: 1)
            image.unlockFocus()
            image.isTemplate = true
            return image
        }

        let font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        let attributed = NSAttributedString(string: "\(percent)%", attributes: attributes)
        let textSize = attributed.size()
        let width = max(glyphSize, ceil(textSize.width)) + 2

        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        // Bottom-left origin: glyph at the top, percentage flush to the bottom.
        // They nominally exceed the bar height, but the overlap lands in the
        // glyph's empty bottom edge and the text's ascender whitespace.
        let glyphRect = NSRect(
            x: (width - glyphSize) / 2, y: height - glyphSize, width: glyphSize, height: glyphSize)
        brand.draw(in: glyphRect, from: .zero, operation: .sourceOver, fraction: 1)
        attributed.draw(at: NSPoint(x: (width - textSize.width) / 2, y: 0))
        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    // MARK: - Popover

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if popover.isShown {
            let wasSame = openButton === sender
            dismiss()
            if wasSame { return }
        }

        let accountID = buttonAccount[ObjectIdentifier(sender)] ?? ""
        let host = NSHostingController(rootView: popoverContent(for: accountID))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        openButton = sender
        // Deliberately do NOT call NSApp.activate here. The app is `.regular` with
        // a persistent "main" window, and activating would yank that window to the
        // front on every icon click — making the popover feel like "Open Agent
        // Manager". The transient popover is button-only (no keyboard), so it's
        // interactive without activating the app; the window is surfaced only via
        // the explicit "Open Agent Manager" action (model.presentMainWindow).
        //
        // Because the app stays in the background, `.transient` won't catch clicks
        // landing in *other* apps, so close on any outside mouse-down ourselves.
        clickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.dismiss()
        }
    }

    /// Close the popover and tear down the outside-click monitor. Safe to call
    /// when nothing is open (no-op).
    private func dismiss() {
        if popover.isShown { popover.performClose(nil) }
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        openButton = nil
    }

    private func popoverContent(for accountID: String) -> AnyView {
        let close: () -> Void = { [weak self] in
            self?.dismiss()
        }
        if !accountID.isEmpty, let account = model.accounts.first(where: { $0.id == accountID }) {
            return AnyView(IndividualMenuView(account: account, model: model, close: close))
        }
        return AnyView(MergedMenuView(model: model, close: close))
    }
}
