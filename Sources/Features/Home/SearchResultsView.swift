import SwiftUI

/// What the page shows while search is open.
///
/// Replaces the carousel and guide rather than filtering them, which is how
/// `.searchable` behaved and what the chip row implies: the scope decides *what
/// kind of thing* you are looking for, so the results have to be that kind of
/// thing rather than a narrowed version of the normal page.
struct SearchResultsView: View {
    @Bindable var model: HomeModel
    let onSelect: (Channel) -> Void

    /// See `GuideSelection` — the selection is the presentation state.
    @State private var programDetail: GuideSelection?

    var body: some View {
        Group {
            switch model.searchScope {
            case .tv: tvResults
            case .series: notBuilt("Series")
            case .movies: notBuilt("Movies")
            }
        }
        .frame(maxWidth: .infinity)
        // **Keyed on the inputs, not on the results.**
        //
        // `value: model.tvResults.map(\.id)` would read the results a second
        // time on every body pass — and computing them means scanning a day of
        // schedule for every channel in the lineup. The query and the toggle are
        // the only things that change them, they are already in hand, and
        // comparing them is free.
        //
        // Short, because it runs on every keystroke and the guide rebuilds
        // every block behind it. Long enough to read as motion, not so long that
        // typing outruns it.
        .animation(.smooth(duration: 0.22), value: model.searchText)
        .animation(.smooth(duration: 0.22), value: model.onNowOnly)
        .animation(.smooth(duration: 0.22), value: model.searchScope)
        .sheet(item: $programDetail) { selection in
            ProgramDetailView(
                selection: selection,
                logoURL: model.catalog.logoURL(for: selection.channel),
                palette: model.logoPalette,
                onPlay: onSelect
            )
        }
    }

    // MARK: - TV

    /// The same guide the homepage draws, holding only the channels that match.
    ///
    /// **The guide rather than a list of rows.** A search hit here is a channel,
    /// and what you want to know about a channel is what is on it — which is the
    /// question the guide already answers. Rendering results as flat rows meant
    /// building a second presentation of the same data that showed strictly
    /// less, and it is why the old Programs scope had to repeat the channel name
    /// in every subtitle.
    @ViewBuilder
    private var tvResults: some View {
        // tvOS only. On iOS the toggle is pinned in `HomeHeader` beside the
        // scope chips, where it stays put — a filter that scrolls out of sight
        // is one you forget you left on. tvOS has no header to pin it to, so it
        // rides above the results instead.
        #if os(tvOS)
            OnNowToggle(isOn: $model.onNowOnly)
                .screenMargin()
        #endif

        if model.query == nil {
            prompt("Search live TV by channel or programme")
                .transition(.opacity)
        } else if model.tvResults.isEmpty {
            ContentUnavailableView.search(text: model.searchText)
                .frame(minHeight: 240)
                .transition(.opacity)
        } else {
            TVGuideView(
                channels: model.tvResults,
                guide: model.guide,
                logoURLFor: model.catalog.logoURL(for:),
                onLogoTap: onSelect,
                // Search results behave like the rest of the guide: a block
                // opens details, the logo plays.
                onProgramTap: { programDetail = $0 },
                palette: model.logoPalette
            )
            // Leading only, matching the homepage and the category page: the
            // guide owns its own trailing margin so it can round the lane off.
            .padding(.leading, Layout.isTV ? Layout.screenMarginH : 0)
        }
    }

    // MARK: - Shared

    private func prompt(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.top, 48)
    }

    /// Honest rather than empty: these screens do not exist yet, and a blank
    /// result list would read as "nothing matched".
    private func notBuilt(_ title: String) -> some View {
        ContentUnavailableView(
            title,
            systemImage: "hammer",
            description: Text("\(title) search isn't built yet.")
        )
        .frame(minHeight: 240)
    }
}

/// Narrows a TV search to what is airing right now.
///
/// Deliberately *not* shaped like a scope chip, even though it sits beside them
/// on iOS. The scopes are a single-select row — picking one drops the last — and
/// a filter that toggles independently reading as a fourth scope would be a lie
/// about how it behaves. Hence the state dot and the fill: on/off, not chosen.
struct OnNowToggle: View {
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(isOn ? Color(red: 0.886, green: 0.294, blue: 0.290) : .secondary)
                    .frame(width: 7, height: 7)
                Text("On Now")
                    .font(.body.weight(isOn ? .semibold : .regular))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
        }
        .glassEffect(
            isOn ? .regular.tint(.accentColor).interactive() : .regular.interactive(),
            in: Capsule()
        )
        .accessibilityLabel("On now")
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }
}
