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
/// 1. **The column is left-aligned, not centred.** The glyph, the headline, the message and the rows
///    all share one leading edge. What is centred is the *column*, via symmetric insets — which
///    reads as balanced without the ransom-note effect of centring a wrapped paragraph.
/// 2. **The type is compact.** A first-run sheet is not a splash screen: the headline sits at
///    roughly `.headline`, not `.largeTitle`, and the rows are smaller still.
///
/// Deliberately not a wizard. Progress dots would promise a longer form than four one-idea steps,
/// and the reference has none. Going back is a chevron in the top-left corner, as it is there.
struct OnboardingPage<Actions: View>: View {
    let symbol: String
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    var rows: [OnboardingRow] = []
    /// `nil` on the first step, which has nowhere to go back to.
    var back: (() -> Void)?
    @ViewBuilder var actions: Actions

    private let inset: CGFloat = 72

    var body: some View {
        ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 0) {
                Image(systemName: symbol)
                    .font(.system(size: 34, weight: .regular))
                    .foregroundStyle(.tint)
                    .padding(.top, 52)
                    .padding(.bottom, 18)

                Text(title)
                    .font(.system(size: 15, weight: .bold))
                    .fixedSize(horizontal: false, vertical: true)

                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)

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
                    .padding(.top, 18)
                }

                Spacer(minLength: 16)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, inset)

            // Back sits over the content rather than in it, so it cannot shift the column by a pixel
            // between steps that have it and the one that does not.
            if let back {
                Button(action: back) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.borderless)
                .background(Color.secondary.opacity(0.12), in: Circle())
                .padding(16)
                .accessibilityLabel("Back")
            }

            VStack {
                Spacer()
                HStack(spacing: 10) { actions }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 18)
            }
        }
        .frame(width: 520, height: 430)
    }
}
