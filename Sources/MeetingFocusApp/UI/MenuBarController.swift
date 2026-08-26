import AppKit
import MeetingFocusCore

/// The menu bar item and the menu that drops out of it.
///
/// AppKit, where `MenuBarExtra` built this until the ⌥ read-out needed the styling macOS gives a
/// detail line — small type, full-strength label colour, indented under the row it belongs to, the way
/// the Wi-Fi menu sets its own. A SwiftUI menu draws every item in the standard menu font and greys
/// anything that is not a control, and it ignores `.font`, `.controlSize` and an AppKit-scoped
/// attributed title alike: all three were measured against a screenshot and came out identical.
/// `NSMenuItem.attributedTitle` is the only thing that sets them, and nothing reaches it from SwiftUI.
///
/// Building the rows in `menuNeedsUpdate` is also what makes ⌥ readable at all. `MenuBarExtra` built
/// its items once and rebuilt them only when observed state changed — never on open, which rendering a
/// timestamp into the menu confirmed — so under it the modifier would have had to arrive as observed
/// state from a global `.flagsChanged` monitor, which needs Accessibility trust to see a keypress.
/// Here it is simply read as the menu opens.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    /// Opening the two SwiftUI scenes. `openWindow` and `openSettings` are environment actions with no
    /// AppKit equivalent, so the `App` that owns those scenes hands them down.
    ///
    /// The defaults complain rather than doing nothing: unwired, these are the app's two ways into
    /// Settings and onboarding, and a menu item that silently no-ops is the hardest kind of broken to
    /// notice.
    var openOnboarding: () -> Void = { Log.state.error("the menu bar's scene actions were never wired") }
    var openSettings: () -> Void = { Log.state.error("the menu bar's scene actions were never wired") }

    private let monitor: MeetingMonitor
    private let settings: AppSettings
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private var optionHeld = false
    /// What the icon currently draws, so an unchanged state does not repaint it. `MeetingMonitor`
    /// reassigns `aggregateState` on every tick whether or not it moved, and `@Observable` reports a
    /// set rather than a change — without this the menu bar icon is rebuilt once a second, forever.
    private var shownState: MeetingState?

    init(monitor: MeetingMonitor, settings: AppSettings) {
        self.monitor = monitor
        self.settings = settings
        super.init()

        // Decided per row rather than inferred: AppKit's default disables every item without an
        // action, which is exactly what the read-out rows are, and a disabled row cannot be styled
        // back out of looking broken.
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu
        observeIcon()
    }

    // MARK: - The icon

    /// The icon and whether it is present at all are the only things that must track state while the
    /// menu is shut. `withObservationTracking` reports one change and then stops, hence the re-arm.
    private func observeIcon() {
        withObservationTracking {
            applyIcon()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeIcon() }
        }
    }

    private func applyIcon() {
        // Both are read before anything else: this closure's reads are what `withObservationTracking`
        // registers, and an early return above one of them would stop the icon tracking it.
        let state = monitor.aggregateState
        let visible = settings.showMenuBarIcon

        if statusItem.isVisible != visible { statusItem.isVisible = visible }
        guard shownState != state else { return }
        shownState = state
        let icon = icon(for: state)
        let image = NSImage(systemSymbolName: icon.symbol, accessibilityDescription: icon.label)
        image?.isTemplate = true
        statusItem.button?.image = image
    }

    /// The label is what VoiceOver reads, so it is a catalogue key rather than plain text — and it
    /// says "Joining a meeting" where the menu's own row says "Joining…", which is the whole reason
    /// the two mappings are separate.
    private func icon(for state: MeetingState) -> (symbol: String, label: String) {
        switch state {
        case .inMeeting: ("video.fill", String(localized: "In a meeting"))
        case .joining: ("video.badge.ellipsis", String(localized: "Joining a meeting"))
        case .idle: ("video", String(localized: "Not in a meeting"))
        }
    }

    // MARK: - NSMenuDelegate

    /// Read once, as the menu opens, and left alone from there — the Wi-Fi and Bluetooth menus decide
    /// their detail rows the same way. Tracking the key while the menu is up would mean holding ⌥ for
    /// as long as you wanted to read, and the block would vanish mid-sentence when you let go.
    ///
    /// Alternate items are the exception, and deliberately so: AppKit swaps those live, and that is
    /// native behaviour every other menu on the system has.
    func menuNeedsUpdate(_ menu: NSMenu) {
        optionHeld = NSEvent.modifierFlags.contains(.option)
        rebuild()
    }

    // MARK: - Building the menu

    private func rebuild() {
        var items = statusRows()
        items += separated(stateRows())
        if optionHeld { items += diagnosticsRows() }
        items += separated(actionRows())

        // Whatever AppKit will indent its own titles by, these rows use too. Asking the finished list
        // rather than restating the condition means a row that grows an image later cannot silently
        // knock the hand-drawn ones out of line.
        let inset = items.contains { $0.image != nil || $0.state != .off } ? MenuColumn.textBesideState : MenuColumn.text
        for case let view as MenuRowView in items.compactMap(\.view) { view.textInset = inset }

        menu.removeAllItems()
        items.forEach { menu.addItem($0) }
    }

    /// A separator ahead of a group, unless the group is empty — two rules in the same place, because
    /// the rows below the state group are all conditional and a lone separator is a visible seam.
    private func separated(_ rows: [NSMenuItem]) -> [NSMenuItem] {
        rows.isEmpty ? [] : [.separator()] + rows
    }

    private func statusRows() -> [NSMenuItem] {
        let status = status(for: monitor.aggregateState)
        var rows = [switchRow(status.text, isOn: monitor.aggregateState == .inMeeting)]
        guard let meeting = monitor.activeMeetings.first else { return rows }

        rows.append(.separator())
        // A title is whatever the meeting is called, so it is shown verbatim rather than as a key.
        rows.append(headline(meeting.title ?? meeting.applicationName))
        rows.append(detail(String(localized: "\(meeting.applicationName) · started \(time(meeting.startedAt))")))
        if monitor.activeMeetings.count > 1 {
            rows.append(detail(String(localized: "+\(monitor.activeMeetings.count - 1) more")))
        }
        return rows
    }

    /// What is wrong and what to do about it — nothing here is a setting. Monitoring has no row
    /// because there is no reason to run the app with detection switched off; quitting is that
    /// gesture, and it is one the menu already offers. Automation keeps its switch in Settings, where
    /// a preference belongs.
    private func stateRows() -> [NSMenuItem] {
        var rows: [NSMenuItem] = []
        // Automation can be on and still do nothing, which the old tick reported as a cross and left
        // the user to work out. Naming the missing piece is more use than reporting it.
        if settings.automationEnabled, !settings.isAutomationConfigured {
            rows.append(ClosureMenuItem(title: String(localized: "Choose Shortcuts…")) { [weak self] in self?.showSettings() })
        }
        if let error = monitor.lastAutomationError {
            rows.append(detail(error))
        }
        if !monitor.accessibilityTrusted {
            // The paragraph explaining why the permission matters cannot live in a menu item; it is
            // in Settings, beside the detector this permission feeds.
            let item = ClosureMenuItem(title: String(localized: "Grant Accessibility permission…")) {
                AccessibilityAuthorization.openSystemSettings()
            }
            item.image = warningSymbol()
            rows.append(item)
        }
        return rows
    }

    /// The technical read-out, revealed by holding ⌥ — the same gesture the Wi-Fi menu uses for its
    /// signal details, and for the same reason: this answers "why did it not fire", a question asked
    /// once a month, not something to spend menu space on.
    private func diagnosticsRows() -> [NSMenuItem] {
        var rows = [NSMenuItem.sectionHeader(title: String(localized: "Diagnostics"))]
        if let meeting = monitor.activeMeetings.first {
            // Which detector claimed the meeting — a marker id, so shown verbatim.
            rows.append(detail(String(localized: "Detected by \(meeting.detectorID)")))
        }
        // Sentences rather than ticks beside nouns: "Not listening for microphone input" says what a
        // hollow circle only implies, and it says it without a column of symbols to decode. Written as
        // two calls rather than one with a ternary inside, because the coverage scan keys on the text
        // immediately before a literal — see the same note in `SettingsView`.
        rows.append(detail(settings.teamsDetectorEnabled
            ? String(localized: "Reading Microsoft Teams' meeting UI")
            : String(localized: "Not reading Microsoft Teams' meeting UI")))
        rows.append(detail(settings.audioDetectorEnabled
            ? String(localized: "Listening for microphone input")
            : String(localized: "Not listening for microphone input")))
        // The words Settings uses for this state, so the two surfaces do not describe it differently.
        rows.append(detail(monitor.accessibilityTrusted
            ? String(localized: "Accessibility granted")
            : String(localized: "Accessibility not granted")))
        rows.append(detail(BuildInfo.summary))

        guard !monitor.recentEvents.isEmpty else { return rows }
        // Flat rather than a submenu: the log is capped at twenty and ten are shown, so it has a
        // maximum height and cannot push the actions below off the screen.
        rows.append(.sectionHeader(title: String(localized: "Recent detections")))
        rows.append(contentsOf: monitor.recentEvents.prefix(10).map { detail($0) })
        return rows
    }

    private func actionRows() -> [NSMenuItem] {
        let settingsItem = ClosureMenuItem(title: String(localized: "Settings…"), keyEquivalent: ",") { [weak self] in
            self?.showSettings()
        }
        return [
            ClosureMenuItem(title: String(localized: "Check for Updates…")) { Updater.shared.checkForUpdates() },
            settingsItem,
            alternate(of: settingsItem, title: String(localized: "Set Up MeetingFocus…")) { [weak self] in
                self?.showOnboarding()
            },
            ClosureMenuItem(title: String(localized: "Quit MeetingFocus"), keyEquivalent: "q") { NSApp.terminate(nil) },
        ]
    }

    /// The row ⌥ swaps in for the one above it. An alternate is AppKit's own mechanism and carries its
    /// own rules: it must directly follow its base item and repeat that item's key equivalent, adding
    /// ⌥ to the modifiers — which is also what gives it a shortcut of its own. Unlike the diagnostics
    /// block, AppKit swaps these while the menu is open, since that is how every other macOS menu
    /// behaves.
    ///
    /// Setup is the alternate rather than the visible row because it is the rarer errand: onboarding
    /// presents itself on a fresh install, and reaching it again is a once-in-a-while repair.
    private func alternate(of base: NSMenuItem, title: String, handler: @escaping () -> Void) -> NSMenuItem {
        let item = ClosureMenuItem(title: title, keyEquivalent: base.keyEquivalent, handler: handler)
        item.keyEquivalentModifierMask = base.keyEquivalentModifierMask.union(.option)
        item.isAlternate = true
        return item
    }

    // MARK: - Rows

    /// The status row: what the app believes, and the switch that overrules it — the shape the
    /// Bluetooth menu gives its header, minus the leading symbol, because the switch is the state
    /// indicator now.
    ///
    /// A view of its own, for the reason `row(_:font:color:image:)` explains, plus one more: an
    /// `NSSwitch` is a control and a menu item's `state` tick is not. AppKit resizes an item's view to
    /// the width of the menu — verified by building this at 120pt and measuring it back at 223 — so
    /// the switch is pinned to the trailing edge by autoresizing rather than by the width guessed
    /// here, and it moves when a longer row widens the menu.
    private func switchRow(_ text: String, isOn: Bool) -> NSMenuItem {
        let toggle = NSSwitch()
        toggle.state = isOn ? .on : .off
        toggle.target = self
        toggle.action = #selector(meetingSwitched(_:))
        toggle.sizeToFit()
        return row(text, font: .menuFont(ofSize: 0), color: .labelColor, trailing: toggle)
    }

    @objc private func meetingSwitched(_ sender: NSSwitch) {
        monitor.setInMeeting(sender.state == .on)
    }

    /// A line at the menu's own size and colour, for the status and the meeting it is about.
    private func headline(_ text: String) -> NSMenuItem {
        row(text, font: .menuFont(ofSize: 0), color: .labelColor)
    }

    /// A detail line, the way macOS sets one: the small system size in the *secondary* label colour,
    /// which is the part that is easy to get wrong in both directions. Sampling the Wi-Fi menu's own
    /// detail lines puts them at white ≈55% against its primary rows at ≈85% — so a row drawn in
    /// `labelColor` reads as another action, and the grey AppKit gives a disabled item (measured at
    /// roughly a quarter of that) reads as broken.
    ///
    /// No image: these rows say their state in words, which leaves nothing for a symbol to add.
    private func detail(_ text: String) -> NSMenuItem {
        row(text, font: .menuFont(ofSize: NSFont.smallSystemFontSize), color: .secondaryLabelColor)
    }

    /// A row that is text rather than a control, drawn by a view of its own.
    ///
    /// Every plainer way fails, and each was measured against a screenshot rather than assumed. An
    /// item with no action is disabled, and AppKit greys a disabled item however its attributed title
    /// is coloured. Leaving it enabled keeps the colour, but then a read-out highlights under the
    /// pointer and closes the menu when clicked. And a plain `title` cannot be sized at all.
    ///
    /// The cost is `Column`, whose numbers AppKit publishes no metric for and which were measured
    /// against a native row — so they can drift if Apple changes the metrics, and a row landing a few
    /// points out of line with the items above it is the whole risk.
    private func row(_ text: String, font: NSFont, color: NSColor, trailing: NSView? = nil) -> NSMenuItem {
        let label = NSTextField(labelWithString: text)
        label.font = font
        label.textColor = color
        label.sizeToFit()

        let item = NSMenuItem()
        // The view draws the row; this is what VoiceOver reads for it. A control inside carries its
        // own accessibility and reaches the tree in its own right.
        item.title = text
        item.view = MenuRowView(label: label, trailing: trailing)
        return item
    }

    /// Where a menu item draws its parts, measured against a native row rather than read from an API,
    /// because AppKit exposes none. Named so that a re-measure on a future macOS is one edit each.
    /// The one item image left in the menu, and the reason `rebuild()` still has to ask whether a
    /// state column exists: this row appears only when the permission is missing, and its presence
    /// moves every title in the menu.
    private func warningSymbol() -> NSImage? {
        NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: NSFont.systemFontSize, weight: .regular))
    }

    // MARK: - Actions and state

    /// Opening a window is not enough on its own: `LSUIElement` puts the app under the accessory
    /// activation policy, where a new window appears behind whatever the user was looking at and an
    /// already-open one stays buried. Activating has to follow the window existing, hence the hop.
    private func activating(_ open: () -> Void) {
        open()
        DispatchQueue.main.async { NSApp.activate(ignoringOtherApps: true) }
    }

    private func showSettings() { activating(openSettings) }
    private func showOnboarding() { activating(openOnboarding) }

    /// Shape, not colour: a menu item's image is drawn as a template, so the green dot the old popover
    /// used would arrive as a grey one. Filled, dashed and hollow read apart in monochrome.
    private func status(for state: MeetingState) -> (text: String, symbol: String) {
        switch state {
        case .inMeeting: (String(localized: "In a meeting"), "circle.fill")
        case .joining: (String(localized: "Joining…"), "circle.dashed")
        case .idle: (String(localized: "Not in a meeting"), "circle")
        }
    }

    private func time(_ date: Date) -> String {
        MeetingMonitor.timeFormatter.string(from: date).prefix(5).description
    }
}
