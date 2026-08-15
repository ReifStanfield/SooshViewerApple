# Soosh — SwiftUI

The Apple-native port of `soosh_viewer`. iOS and tvOS targets, one shared
`Sources/` tree.

## First run

```bash
cp Config/Local.xcconfig.example Config/Local.xcconfig   # then fill it in
xcodegen generate
open SooshViewer.xcodeproj
```

Requires Xcode 26 and an iOS/tvOS 26 device or simulator — see Liquid Glass
below.

`Local.xcconfig` is gitignored. It carries the server URL and credentials that
Flutter passes as `--dart-define`; they travel into `Info.plist` as build
settings and `AppConfig` reads them back out at runtime.

Note the `$()` in the example URL — `//` starts a comment in xcconfig, so an
empty build-setting reference has to break up `https://`.

**Re-run `xcodegen generate` after adding files.** The `.xcodeproj` is generated
and gitignored; `project.yml` is the source of truth.

## Layout

```
Sources/App/        Entry point, tab bar.
Sources/Data/       Client, models, repositories. No SwiftUI imports.
Sources/Features/   One folder per screen: view + its @Observable model.
```

The `Data` layer mirrors `lib/data/` one file at a time, including its
hard-won API notes — see the Flutter project's CLAUDE.md for *why* the
`effective_*` fields, the `tvg_id` bridge, and the three response envelopes are
handled the way they are. Those constraints did not change with the language.

## Tests

```bash
xcodebuild test -project SooshViewer.xcodeproj -scheme Soosh-iOS \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

12 tests, all passing. They pin the connect/retry loop with a scripted fake
engine — the same role `test/playback_test.dart` plays on the Flutter side.
The suite takes ~46s because the loop is time-driven and the backoff delays
are real.

## Done so far

- Auth (login + single-flight refresh-on-401), paging, envelope unwrapping.
- Channel / Logo / Program / EPGData models with lenient decoding.
- Home: Continue Watching carousel, guide list with now-playing + progress,
  search, pull to refresh, tab bar.
- Playback: AVPlayer behind `PlaybackEngine`, the stall-timeout connect loop
  ported intact.
- Custom player controls on iOS (`PlayerControlsView`): back, play/pause with a
  buffering spinner, AirPlay, PiP, fullscreen rotate, subtitle and audio track
  pickers, read-only EPG timeline with LIVE badge, 4s auto-hide.
  Share / favourite / multiview / overflow render but are `TODO` stubs.
- tvOS keeps `AVPlayerViewController` and its system controls — see the note in
  `PlayerView.body` for why that is deliberate, not unfinished.

### `automaticallyWaitsToMinimizeStalling` must stay `true`

It was set to `false` in `AVPlayerEngine.init` on the theory that a live stream
should start at the live edge rather than buffer first. That is wrong for HLS:
with waiting disabled the player will not hold at rate 0 while the first
segments arrive — it drops the requested rate to 0 and never picks it back up.
The symptom is a first frame on screen, `timeControlStatus == .playing`, and
`currentTime()` pinned at 0.00 forever.

It survived two rounds of testing because `AVPlayerViewController` resets this
property on any player handed to it. Swapping to a bare `AVPlayerLayer` for the
custom controls removed that safety net and exposed the original mistake.

### `@State(initialValue:)` runs on every rebuild

It keeps the first result and discards the rest — but they are all constructed.
`State(initialValue: AVPlayerEngine())` therefore allocated a new engine on every
view rebuild. Survivable until each one called `AVAudioSession.setActive(true)`
in its initialiser; the session is process-wide, so throwaway engines kept
interrupting the real one.

Both fixes are in place: the model is built lazily in `.task`, and the audio
session is configured in `open()` rather than `init`.

### Liquid Glass

Deployment target is **iOS/tvOS 26**, so `glassEffect` is available
unconditionally. That deliberately drops every device below 26 — fine for a
personal-server app, and the reason it is stated in `project.yml`.

- **One `GlassEffectContainer` wraps the whole control layer**, not one per pill.
  The container is what lets separate glass shapes sample a shared backdrop and
  blend when they come near each other; a container per pill defeats that and
  costs an extra render pass each.
- **Glass goes on the pill, not on each button inside it.** Per-child
  `glassEffect` gives every glyph its own capsule and the row stops reading as
  one cluster.
- **`.interactive()` only on standalone buttons** (back, play/pause), where the
  glass itself is the tap target. Pills leave it off because their children own
  the interaction.
- The gradient scrim stays *under* the glass: glass alone does not guarantee
  white glyphs stay legible over a bright scene.

### The progress bar is the stock `Slider`

There is **no "glass slider style"** in iOS 26 — the system `Slider` simply *is*
Liquid Glass now, so adopting it is how you get the real material and its motion.
What iOS 26 actually adds is `sliderThumbVisibility`, `neutralValue`,
`enabledBounds`, and tick marks.

Because the timeline is read-only, two things follow:

- `.allowsHitTesting(false)`, **not** `.disabled(true)` — disabling greys it out;
  this keeps the enabled appearance while making it inert.
- `.accessibilityRepresentation { ProgressView(...) }`, so VoiceOver announces
  progress rather than an adjustable control it cannot actually adjust.

If the thumb reads as a false affordance, `.sliderThumbVisibility(.hidden)`
removes it in one line. Making it genuinely seekable would mean mapping to
AVPlayer's seekable range instead of the EPG programme — see the note on
`timeline`.

### Two layout traps this hit, both worth knowing

**Safe area.** `.ignoresSafeArea()` was applied to the whole player, which laid
the top control row out *under the Dynamic Island*. The island then covered the
share button, and it looked exactly like a clipped view — three wrong fixes went
into the AirPlay button before the real cause surfaced. The video ignores the
safe area; the controls do not. If chrome is mysteriously obscured at a screen
edge, check the safe area before blaming a view.

**Control chrome must be lighter than its darkest backdrop.** The pills were
`.black.opacity(0.55)`, invisible over letterboxed video. They are now a fixed
light grey.

## The black-screen bug, and why it was misdiagnosed

Worth reading before debugging playback here, because the symptom points away
from the cause.

`PlayerView` held its engine in a plain `private let`. A SwiftUI `View` is a
struct that gets recreated on every rebuild, so `init` ran repeatedly and built
a **new** `AVPlayerEngine` — with a new, empty `AVPlayer` — each time. The
model is `@State`, so it survived and kept playing on the *original* engine.
The result: a completely healthy connection on the Dispatcharr side, correct
`.playing` state in the app, and a black screen, because `body` was handing
AVKit a different player that had no item.

The fix is `@State private var engine`. **Rule: every stored property of a
`View` that must outlive a rebuild needs `@State`. A plain `let` holding a
reference type is a new object on every rebuild.**

This was first misread as a codec or iOS Simulator rendering limitation, on the
strength of ffprobe showing FS1 as H.264 High 1080p + AAC-LC. It was neither —
both ESPN and FS1 play with picture in the Simulator once the lifetime bug is
fixed. AVPlayer has now been verified against two channels; the wider lineup
still deserves a spread test, and tvOS has not been run on hardware.

Note that probing streams costs provider connection slots: `/proxy/ts/stream/`
returned "All active M3U profiles have reached maximum connection limits"
during testing. That failure is exactly what the retry backoff exists for.

## tvOS

The TV build is a real fork of the *chrome*, not a scaled phone layout.

- **`.buttonStyle(.plain)` is poison on tvOS.** It strips the focus effect, so a
  focused card is indistinguishable from an unfocused one and the remote appears
  dead. Every tappable surface here was `.plain`. Use `cardButtonStyle()` /
  `rowButtonStyle()` in `PlatformStyle.swift`, which map to `.card` / `.borderless`
  on TV and `.plain` elsewhere.
- **A pinned search field is a focus trap.** The remote catches it on every pass
  up or down the page. On tvOS the header is gone entirely and search is its own
  tab using `.searchable` + `.searchScopes`, which brings the system keyboard and
  scope bar with it. `TabView` already provides the page switching and settings
  that the phone header's menu and gear do.
- **`focusSection()`** groups the carousel, the guide, and each guide row, so
  movement is predictable instead of landing on whatever is geometrically
  nearest.
- **The player is a `fullScreenCover`, not a navigation push.** `TVSidebarShell`
  insets its content by the collapsed rail and slides it sideways when the rail
  expands; a pushed destination inherits both, so the picture sat 120pt in from
  the left and shifted whenever focus touched the sidebar. A cover is presented
  above the shell and owns the whole panel. `onExitCommand` handles Menu, since
  there is no navigation bar to go back through.
- **Ten-foot metrics** live in `Layout` and the `#if os(tvOS)` constants at the
  top of `GuideGeometry.swift`: ~5% overscan margins, taller guide rows, wider
  time axis, larger cards and fonts. `guideRowCount` is fixed at 4 on TV — a
  1080p panel is 1920pt wide, so the width classes call it "expanded" and hand it
  10 rows, right for a desktop window and wrong from a sofa.

`RootView` owns the `HomeModel` so the Home and Search tabs share one catalog and
guide rather than fetching twice, and it builds it in `.task` rather than an
initialiser for the reason described under *`@State(initialValue:)` runs on every
rebuild*.

## The pinned home header

`HomeHeader` (page menu, settings, search) is attached with
`safeAreaInset(edge: .top)`, **not** `.navigationTitle` + `.searchable`. Both of
those scroll away by design — a large title collapses, the system search field
slides up — and all three controls are meant to stay put. `safeAreaInset` also
insets the scroll view by exactly the header's height, so there is no manual
clearance constant (the Flutter version's `_toolbarClearance = 88`) to keep in
sync.

Content scrolls *under* the header, which means it also reaches the status-bar
strip above it. `.scrollEdgeEffectStyle(.hard, for: .top)` is iOS 26's answer:
it fades content where it meets a pinned bar. Without it, headings visibly ride
up over the clock.

It has two states, like `.searchable`: focusing the field drops the page menu
and settings button, adds a close button beside the field, and reveals the scope
chips. **The search field is not inside the `if`** — both states are expressed by
what appears *around* it, so SwiftUI keeps the same view identity across the
transition and animates it moving up. Putting it in both branches of an if/else
would also drop focus mid-transition.

The chip row gets its **own nested `GlassEffectContainer(spacing: 0)`**. The
header's outer container merges glass within 20pt, which is the point for the
pills up top and exactly wrong for chips sitting 10pt apart — they fused into one
blob with the selected one bleeding into its neighbour.

Scopes are single-select. `Channels` and `Programs` search real data (programme
matches are capped at 100 — the guide holds ~24h per channel, so a two-letter
query would otherwise build thousands of rows). `Series` and `Movies` are
selectable rather than disabled, and say plainly that they are not built yet — a
greyed-out chip reads as broken, and an empty list reads as "nothing matched".

## The guide

`TVGuideView` is a port of `epg_widget.dart`: rows are channels, the x axis is
time, the logo column is pinned, and block labels slide sideways to stay visible
as their block passes under it. Not virtualised, same as the original —
`maxRows` is what bounds the work.

Two SwiftUI-specific notes:

- **`GuideScrollPosition` is `@Observable`, not `@State`.** Only the block
  *labels* read the scroll offset. Holding it in `@State` on the guide would
  invalidate the whole grid on every scroll frame; `@Observable` tracks reads per
  property, so only the labels re-evaluate. It is the direct counterpart of the
  Flutter version's `ValueListenableBuilder`, which existed for the same reason.
- **Scrolling to "now" uses `ScrollPosition`, not `ScrollViewReader`.** The
  target is a *time*, i.e. a pixel offset. The first attempt anchored on a
  zero-width marker pushed into place with `.offset(x:)` — which silently does
  nothing, because `.offset` is a render transform and the marker's layout
  position is still x = 0.

`LogoPalette` is a direct port of `logo_palette.dart`, including every threshold.
It samples the border *ring* rather than taking a dominant colour, so ESPN's
cut-out wordmark correctly yields no plate while FS1's navy box does. One actor
instance is shared between the carousel and the guide, caching the `Task` per URL
so each logo is downloaded and analysed once.

## Settings

`SettingsView` ports `settings_screen.dart` and its General detail page. Two
pieces of Flutter machinery have no counterpart and were simply deleted:

- **`showAppSheet()`'s size branching.** `.sheet` already adapts — full height on
  a phone, a centred form sheet on a regular-width window.
- **`useNestedNavigation` and `TopBar._defaultBack`.** A `NavigationStack`
  *inside* the sheet is the nested navigation. In Flutter, `Navigator.pop` on the
  sheet's first page succeeds, strands an empty nested Navigator and renders a
  blank box, so the back button has to branch on `canPop()`. Here dismissal and
  back are different mechanisms and cannot be confused: `Done` calls `dismiss()`,
  Back only exists when there is a page behind.

`List` with sections also replaces `_SectionCard`'s hand-drawn hairlines and
`SettingsRow`'s hand-drawn chevron.

Values live in an app-level `SettingsStore`, so they survive closing and
reopening the sheet — the Flutter `SettingsDetailPage` is a `StatefulWidget`
rebuilt per push, so its state resets. Deliberately **not** `@AppStorage`:
nothing consumes these yet, and persisting them would make them look wired up.

## Not yet

- The unbuilt settings rows (User interface, Video player, Backup, EPG, DVR
  server, Add playlist, and the three storage cleanups) push a "not wired up yet"
  page rather than doing nothing, matching the Flutter SnackBar's intent.
- The Pages menu entries in `HomeHeader`.
- Logo-derived card colours (`logo_palette.dart`). Cards use the stable
  neutral palette for now.
- tvOS layout pass: overscan margins, ten-foot type, deliberate focus order.
  It builds and runs, but it is the phone layout on a TV.
