import AppKit

/// An item that runs a closure. AppKit's target–action wants a selector on some object, and every row
/// below would otherwise need a method of its own on the controller.
final class ClosureMenuItem: NSMenuItem {
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

/// Where a menu item draws its parts.
///
/// Both title positions are measured against an AppKit-drawn row, because there is no API for either,
/// so both can drift if Apple changes the metrics.
enum MenuColumn {
    /// Where a title starts when nothing in the menu reserves a state column, and where it starts
    /// when something does.
    static let text: CGFloat = 14
    static let textBesideState: CGFloat = 41
    /// Where a control on the trailing edge stops, level with the column AppKit puts key equivalents
    /// in. Not the same number as `text` even though both measure 17pt on screen: a label's frame
    /// starts about 3pt before its first glyph, and a control's does not.
    static let trailing: CGFloat = 17
    static let padding: CGFloat = 3
    static let minimumHeight: CGFloat = 20
    /// The least that may sit between a row's label and a control on its trailing edge.
    static let gap: CGFloat = 24
}

/// A row that draws its own contents, and can be told where the menu's title column is.
///
/// The column is a property of the menu as built, not a constant: AppKit reserves room for state
/// ticks and item images only when some item in the menu needs it, and indents every title by that
/// column's width when it does. Two checkmark rows once made that permanent here; removing them moved
/// every AppKit-drawn title 27pt left and stranded these hand-drawn ones where they were. So the
/// inset is measured off the finished item list in `rebuild()` and pushed down, rather than written
/// in as a number that is right for one version of the menu.
final class MenuRowView: NSView {
    private let label: NSTextField
    private let trailing: NSView?

    /// Moving the title column changes how wide the row wants to be, so the frame is refreshed with
    /// it: the menu is sized from what its item views ask for.
    var textInset: CGFloat = 0 {
        didSet {
            invalidateIntrinsicContentSize()
            setFrameSize(intrinsicContentSize)
            needsLayout = true
        }
    }

    init(label: NSTextField, trailing: NSView?) {
        self.label = label
        self.trailing = trailing
        let height = max(label.frame.height, trailing?.frame.height ?? 0) + MenuColumn.padding * 2
        super.init(frame: NSRect(x: 0, y: 0, width: 0, height: max(height, MenuColumn.minimumHeight)))
        // What actually makes AppKit widen this row to the menu: the menu resizes the view it hosts
        // the item in, and without the mask the row keeps its own width and its trailing control sits
        // wherever that width put it — short of the edge on any menu made wider by another row.
        autoresizingMask = [.width]
        addSubview(label)
        if let trailing { addSubview(trailing) }
        setFrameSize(intrinsicContentSize)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("MenuBarController builds its rows in code") }

    /// What the row would like to be. AppKit sizes an item's view to the menu's width — wider for a
    /// row narrower than the menu, and narrower than asked for when this row is the widest one — so
    /// this is a request, and `layout()` is what actually has to hold.
    override var intrinsicContentSize: NSSize {
        var width = textInset + label.frame.width + MenuColumn.trailing
        if let trailing { width += MenuColumn.gap + trailing.frame.width }
        return NSSize(width: width, height: frame.height)
    }

    /// A resize is the moment the trailing control has to move, and a frame change does not schedule
    /// layout by itself for a row laid out in code.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    /// Positioned from `bounds`, never from the width this row asked for. Laying the trailing control
    /// out against a computed width is what pushed the switch past the menu's edge: AppKit had given
    /// the view a different width by then, and nothing recomputed.
    override func layout() {
        super.layout()
        label.setFrameOrigin(NSPoint(x: textInset, y: (bounds.height - label.frame.height) / 2))
        trailing?.setFrameOrigin(NSPoint(
            x: bounds.width - MenuColumn.trailing - (trailing?.frame.width ?? 0),
            y: (bounds.height - (trailing?.frame.height ?? 0)) / 2
        ))
    }
}
