import SwiftUI

/// One row of the icon-and-text column: a glyph, a short bold title, and a line or two explaining it.
struct OnboardingRow: Identifiable {
    let id: String
    let symbol: String
    let title: LocalizedStringKey
    let detail: LocalizedStringKey

    init(symbol: String, title: LocalizedStringKey, detail: LocalizedStringKey) {
        self.id = symbol
        self.symbol = symbol
        self.title = title
        self.detail = detail
    }
}

/// The shape macOS uses for a first-run sheet — matched against Apple's own Platform SSO setup pane.
///
/// Two details that are easy to get backwards, both taken from that reference:
///
/// 1. **The column is left-aligned, not centred.** The glyph, the headline, the message, the rows
///    and the chevron above them all share one leading edge, via `inset`. What is centred is the
///    *column*, via that symmetric inset — which reads as balanced without the ransom-note effect
///    of centring a wrapped paragraph.
///
///    The action row deliberately does **not** share that inset: it hugs the card's edges instead
///    (`.padding(.horizontal, 20)`), the way a window's own controls do, rather than lining up with
///    the paragraph above it. This was tried the other way — one inset for everything, including
///    the action row — and rejected: it read as less consistent, not more, and lost the proportions
///    of the reference. Don't unify the two again without a reason to.
/// 2. **The type is compact.** A first-run sheet is not a splash screen: the headline sits at
///    roughly `.headline`, not `.largeTitle`, and the rows are smaller still.
///
/// Deliberately not a wizard. Progress dots would promise a longer form than four one-idea steps,
/// and the reference has none. Going back is a chevron in the top-left corner, as it is there —
/// aligned with the content column's leading edge, not the card's raw corner; its exact position
/// is a known, accepted limitation and not worth further iteration.
struct OnboardingPage<Actions: View>: View {
    let symbol: String
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    var rows: [OnboardingRow] = []
    /// `nil` on the first step, which has nowhere to go back to.
    var back: (() -> Void)?
    @ViewBuilder var actions: Actions

    @Environment(\.dismissWindow) private var dismissWindow

    private let inset: CGFloat = 72
    // Measured from a screenshot, not computed: `.glass` adds its own padding around the 30×30
    // icon frame, which isn't visible from the source. The button renders at 38pt tall.
    private let chevronHeight: CGFloat = 38

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The content column: glyph, headline, message, rows and the chevron above them, all
            // inset for readable line length rather than hugging the card's edges.
            VStack(alignment: .leading, spacing: 0) {
                // Always present, whether or not `back` is set, so this row reserves the same
                // height on every step and the rest of the column never shifts.
                Group {
                    if let back {
                        Button(action: back) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 14, weight: .semibold))
                                .frame(width: 30, height: 30)
                        }
                        .buttonStyle(.glass)
                        .buttonBorderShape(.circle)
                        .accessibilityLabel("Back")
                    } else {
                        Color.clear
                    }
                }
                .frame(height: chevronHeight, alignment: .leading)

                Image(systemName: symbol)
                    .font(.system(size: 34, weight: .regular))
                    .foregroundStyle(.tint)
                    .padding(.top, 24)

                Text(title)
                    .font(.system(size: 15, weight: .bold))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 16)

                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)

                if !rows.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(rows) { row in
                            // `Label`, not a bare `HStack`: it groups the glyph and both lines into
                            // one accessibility element, so VoiceOver reads a row as a row rather
                            // than three unrelated fragments. There is no public SwiftUI component
                            // for the page as a whole — Apple's own first-run sheets use the private
                            // OnBoardingKit — so this is as close to first-party as it gets.
                            Label {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(row.title).font(.system(size: 11, weight: .semibold))
                                    Text(row.detail)
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            } icon: {
                                Image(systemName: row.symbol)
                                    .font(.system(size: 15))
                                    .foregroundStyle(.tint)
                                    .frame(width: 22, alignment: .center)
                            }
                        }
                    }
                    .padding(.top, 24)
                }

                Spacer(minLength: 16)
            }
            .padding(.horizontal, inset)

            // Hugs the card's edges rather than the content column's inset — a corner control,
            // the way a window's own controls sit close to its edges.
            HStack(spacing: 10) { actions }
                .padding(.horizontal, 20)
                .padding(.bottom, 18)
        }
        // Top is deliberately `0`: the window is still `.titled`, so SwiftUI reserves a safe-area
        // inset above the content for the (hidden) title bar, and `.windowResizability(.contentSize)`
        // sizes the window to the content frame plus that inset. That reserved inset already *is*
        // the space above the chevron — a safe area is the system telling us where not to put
        // content — so adding our own top padding on top of it would double it, and fighting it
        // with `.ignoresSafeArea()` only relocates the surplus to the bottom instead of removing
        // it. Pairs with `WindowChrome.fullSizeContentView`, which is what makes the window paint
        // its own background behind that inset region instead of leaving a distinct title bar.
        .padding(.top, 0)
        .frame(width: 520, height: 430)
        // The close button is gone with the chrome, and an LSUIElement app has no Dock tile to fall
        // back on. Escape leaves the window without completing, which the resume logic already
        // handles — `onboardingStep` is saved, so reopening returns to the same place. `dismiss()`
        // is for hierarchical presentations (sheets, popovers) and does nothing for a top-level
        // `Window` scene; `dismissWindow()` with no arguments is the one that actually closes the
        // window the environment belongs to.
        .onExitCommand { dismissWindow() }
    }
}
