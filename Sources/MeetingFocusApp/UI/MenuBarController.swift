import AppKit
import MeetingFocusCore

/// An item that runs a closure. AppKit's target–action wants a selector on some object, and every row
/// below would otherwise need a method of its own on the controller.
private final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, keyEquivalent: String = "", handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: keyEquivalent)
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("MenuBarController builds its items in code") }

    @objc private func run() { handler() }
}

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
        var items = statusRows() + [.separator()] + stateRows()
        if optionHeld { items += diagnosticsRows() }
        items += [.separator()] + actionRows()

        menu.removeAllItems()
        items.forEach { menu.addItem($0) }
    }

    private func statusRows() -> [NSMenuItem] {
        let status = status(for: monitor.aggregateState)
        var rows = [headline(status.text, symbol: status.symbol)]
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

    /// Switches rather than read-outs. A row carrying a tick nobody can click reads as a broken
    /// checkbox, and both of these states have something behind them the user is allowed to change.
    private func stateRows() -> [NSMenuItem] {
        var rows = [
            toggle(String(localized: "Monitoring"), isOn: monitor.isMonitoring) { [monitor] in
                Task { monitor.isMonitoring ? await monitor.stop() : await monitor.start() }
            },
            toggle(String(localized: "Automation"), isOn: settings.automationEnabled) { [settings] in
                settings.automationEnabled.toggle()
            },
        ]
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
            item.image = symbol("exclamationmark.triangle")
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

    /// A line at the menu's own size and colour, for the status and the meeting it is about.
    private func headline(_ text: String, symbol name: String? = nil) -> NSMenuItem {
        row(text, font: .menuFont(ofSize: 0), color: .labelColor, image: name.flatMap { symbol($0) })
    }

    /// A detail line, the way macOS sets one: the small system size in the *secondary* label colour,
    /// which is the part that is easy to get wrong in both directions. Sampling the Wi-Fi menu's own
    /// detail lines puts them at white ≈55% against its primary rows at ≈85% — so a row drawn in
    /// `labelColor` reads as another action, and the grey AppKit gives a disabled item (measured at
    /// roughly a quarter of that) reads as broken.
    ///
    /// No image: these rows say their state in words, which leaves nothing for a symbol to add.
    private func detail(_ text: String) -> NSMenuItem {
        row(text, font: .menuFont(ofSize: NSFont.smallSystemFontSize), color: .secondaryLabelColor, image: nil)
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
    private func row(_ text: String, font: NSFont, color: NSColor, image: NSImage?) -> NSMenuItem {
        let label = NSTextField(labelWithString: text)
        label.font = font
        label.textColor = color
        label.sizeToFit()

        let height = max(label.frame.height + Column.padding * 2, Column.minimumHeight)
        label.setFrameOrigin(NSPoint(x: Column.text, y: (height - label.frame.height) / 2))
        let width = Column.text + label.frame.width + Column.trailing
        let view = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        if let image {
            let side = Column.imageSide
            let well = NSImageView(frame: NSRect(x: Column.image, y: (height - side) / 2, width: side, height: side))
            well.image = image
            well.contentTintColor = color
            view.addSubview(well)
        }
        view.addSubview(label)

        let item = NSMenuItem()
        // The view draws the row; this is what VoiceOver reads back.
        item.title = text
        item.view = view
        return item
    }

    /// Where a menu item draws its parts, measured against a native row rather than read from an API,
    /// because AppKit exposes none. Named so that a re-measure on a future macOS is one edit each.
    private enum Column {
        /// Where an item's title starts, and where the image column before it sits.
        static let text: CGFloat = 41
        static let image: CGFloat = 24
        static let imageSide: CGFloat = 14
        static let padding: CGFloat = 3
        static let trailing: CGFloat = 12
        static let minimumHeight: CGFloat = 20
    }

    private func toggle(_ title: String, isOn: Bool, handler: @escaping () -> Void) -> NSMenuItem {
        let item = ClosureMenuItem(title: title, handler: handler)
        item.state = isOn ? .on : .off
        return item
    }

    private func symbol(_ name: String, small: Bool = false) -> NSImage? {
        let size = small ? NSFont.smallSystemFontSize : NSFont.systemFontSize
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: .regular))
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
