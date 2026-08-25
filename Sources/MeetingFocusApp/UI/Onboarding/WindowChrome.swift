import AppKit
import SwiftUI

/// Reaches through to the onboarding window's backing `NSWindow` and hides its remaining chrome:
/// the title bar's traffic lights and its separator hairline.
///
/// This exists because there is no public SwiftUI API for hiding the standard window buttons. The
/// one window style that does hide them, `.plain`, produces a borderless window — and
/// `NSWindow.canBecomeKey` is false for borderless windows, which silently kills all keyboard input
/// (Escape, Return, Tab, VoiceOver) for the whole window. `.hiddenTitleBar` keeps `.titled` in the
/// style mask, which is what lets the window become key, so this view does the rest by hand
/// instead. Do not "simplify" this back to `.plain` — it looks identical but silently breaks the
/// keyboard again.
///
/// A wider, 26pt corner radius was also tried here, which needed a transparent window background
/// to show through a clipped shape. That in turn killed the system shadow (which follows the
/// window's rectangular frame, not the clipped shape inside it), forcing a hand-drawn replacement
/// shadow, padding to give it room, and it broke background dragging along the way — one wish,
/// three cascading workarounds. It was abandoned in favour of the system's own corner radius and
/// shadow, both of which come for free once the window background is left alone. Do not reach for
/// that again without solving dragging and the shadow first.
///
/// Attach once, on `OnboardingView.body`, not per page: attaching it inside `OnboardingPage` would
/// run this configuration once per step for no benefit.
struct WindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        // The view has no window yet on this pass; the window is attached shortly after, so
        // configuration is deferred to the next run-loop turn.
        DispatchQueue.main.async { [weak view] in
            configure(view?.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // SwiftUI can re-create the hosting view underneath this representable; reapplying here
        // is what makes the configuration survive that instead of only holding on the first frame.
        configure(nsView.window)
    }

    private func configure(_ window: NSWindow?) {
        guard let window else { return }
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        // `.hiddenTitleBar` leaves the titlebar/content separator behind as a stray hairline
        // across the top of the card; this is what removes it.
        window.titlebarSeparatorStyle = .none
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        // `.hiddenTitleBar` hides the title bar but does not let content extend underneath it —
        // without this, the window paints a distinct title-bar-coloured strip above the content.
        // This lets the window's content view occupy the whole window instead, so the safe-area
        // inset SwiftUI still reserves for that (hidden) title bar is drawn with the same
        // background as everything else. `OnboardingPage` uses that inset as its own top padding
        // (`.padding(.top, 0)`, deliberately) rather than fighting it — the two are a pair, 100
        // lines apart, and neither alone gets the spacing right.
        window.styleMask.insert(.fullSizeContentView)
    }
}
