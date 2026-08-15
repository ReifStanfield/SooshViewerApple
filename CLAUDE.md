# Soosh — SwiftUI (iOS + tvOS)

The Apple-native port of `../soosh_viewer` (Flutter). Same Dispatcharr server,
same data model, native UI. **Both apps are live** — the Flutter one is not
deleted, and its `CLAUDE.md` is still the authority on the API's behaviour.

> **This directory is outside the git repo.** The repo root is
> `../soosh_viewer`, so nothing here is version-controlled. Moving it inside is a
> one-line `mv`, still undone.

## Running it

```bash
cp Config/Local.xcconfig.example Config/Local.xcconfig   # fill in, gitignored
xcodegen generate
open SooshViewer.xcodeproj
```

```bash
xcodebuild -project SooshViewer.xcodeproj -scheme Soosh-iOS \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
xcodebuild test -project SooshViewer.xcodeproj -scheme Soosh-iOS \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'      # 32 tests
xcodebuild -project SooshViewer.xcodeproj -scheme Soosh-tvOS \
  -destination 'generic/platform=tvOS Simulator' build
```

**Re-run `xcodegen generate` after adding files.** The `.xcodeproj` is generated
from `project.yml` and gitignored; a new file that is not in the project will
fail with "cannot find X in scope" even though it compiles fine in the editor.

Requires **Xcode 26**; deployment target is **iOS/tvOS 26** so Liquid Glass is
available unconditionally. That deliberately drops older devices.

`Config/Local.xcconfig` carries the server URL, credentials and
`DEVELOPMENT_TEAM`. Two traps: `//` starts a comment in xcconfig (hence the
`$()` in the URL), and **a build setting written in `project.yml` outranks the
same key from an xcconfig** — which is why `DEVELOPMENT_TEAM` is deliberately
absent from the manifest.

## Layout

```
Sources/Data/         Client, models, repositories. No SwiftUI imports.
Sources/Playback/     PlaybackEngine protocol + AVPlayerEngine.
Sources/Presentation/ Colour maths, logo palette, platform styles, backdrop.
Sources/Features/     One folder per screen: view + its @Observable model.
                      Category/ takes HomeModel rather than owning one — a
                      second model is a second full fetch of the lineup.
Sources/App/          Entry point, RootView, the two sidebar shells.
                      SidebarDestination is shared; the chrome is not.
Tests/                32 tests: connect loop + logo palette.
```

---

## The data layer is a faithful port — read the Flutter CLAUDE.md

Every API quirk documented in `../soosh_viewer/CLAUDE.md` still applies: the
`effective_*` fields typed as `string`, the three response envelopes, programmes
joining to channels by `tvg_id` with the `epg_data_id` bridge, the stream URL
taking the **UUID**, and 30-minute JWTs. Those are facts about the server, not
about Dart.

Two things Swift does better and one place it is stricter:

- **`DispatcharrClient` is an `actor`.** The hand-rolled single-flight refresh
  guard is unnecessary; actor isolation gives it.
- **`async let`** replaces `Future.wait`.
- **`Codable` is strict**, and this API is not. Everything numeric or optional
  goes through `LooseJSON.swift`, which accepts whichever JSON type actually
  turns up and coerces. `"None"`, `""` and `"null"` are treated as nil.

---

## Playback

`PlaybackEngine` survives the port for a different reason than in Flutter. There
it existed because media_kit has no tvOS build; here AVPlayer is the only engine.
It stays because the connect/retry loop is the most load-bearing logic in the app
and a protocol lets `PlaybackConnectTests` drive it with a scripted fake.

`PlayerModel` is a faithful port of the stall-timeout connect loop — **do not
"simplify" it**, for the reasons in the Flutter CLAUDE.md. One thing genuinely is
simpler: Flutter needs `_openGen` *and* future-chaining to stop overlapping
connect loops; Swift's `Task` does both (cancel, then `await previous?.value`).

### Three playback bugs that cost real time

- **`automaticallyWaitsToMinimizeStalling` must stay `true`.** Setting it false
  for "start at the live edge" makes AVPlayer drop the requested rate to 0 and
  never resume: one frame on screen, `timeControlStatus == .playing`,
  `currentTime()` pinned at 0.00 forever. It hid for two rounds because
  **`AVPlayerViewController` resets this property on any player handed to it** —
  only surfaced after moving to a bare `AVPlayerLayer`.
- **`hasAudio` must mean "this stream carries no video track"**, not "no frame
  has arrived yet". Live HLS runs audio well before the first decodable frame, so
  the wrong test declared success on a black screen.
- **Pause before releasing.** AVPlayer keeps filling its read-ahead buffer until
  paused, so dropping the item while playing leaves the socket open and
  Dispatcharr counts the channel as in use.

### Player structure

Both platforms draw into a bare **`AVPlayerLayer`** (`VideoLayerView`), not
`AVPlayerViewController` — a controller with `showsPlaybackControls = false`
still owns gestures and insets the layout, and it never exposes the layer that
`AVPictureInPictureController` needs.

- iOS: `PlayerControlsView` — glass pills, EPG timeline as a stock `Slider`.
- tvOS: `TVPlayerControlsView` — info panel left, circular controls right,
  segmented timeline. Presented as a **`fullScreenCover`**, because a navigation
  push inherits the sidebar's inset and offset.

---

## SwiftUI lessons this codebase paid for

**`@State(initialValue:)` evaluates its argument on every `init`.** It keeps the
first result and discards the rest — but they are all constructed. This broke
playback twice: first as a plain `let` holding the engine, then as `@State` whose
initial value allocated a fresh engine each rebuild, each one calling
`AVAudioSession.setActive(true)` and interrupting the real player. **Build
expensive or side-effecting objects in `.task`, not in `init`.** `RootView` and
`PlayerView` both do.

**Symptom-to-cause mismatches seen here, all diagnosed only by instrumenting or
by deleting the suspect:**

| Symptom | Actual cause |
|---|---|
| Black video, healthy server connection | View-lifetime bug, not codecs |
| Chrome clipped at a screen edge | Content laid out under the Dynamic Island |
| Control chrome invisible | Dark scrim over letterboxed (black) video |
| Snapping never works, no warning | `scrollTargetBehavior` on the content, not the ScrollView |
| Guide scrolled to the wrong place | Scroll fired before the row budget settled |

**Reach for instrumentation early.** `xcrun simctl launch --console-pty` plus a
periodic dump of real state settled in one run what three rounds of reasoning
from screenshots got wrong.

**Other specifics:**

- `.offset` is a render transform; `ScrollViewReader` scrolls to *layout*
  positions. Use `ScrollPosition.scrollTo(x:)` when the target is an offset.
- `.contentMargins(..., for: .scrollContent)` rather than `.padding` on a
  snapping ScrollView, so a snapped item aligns with the rest of the page.
- `GlassEffectContainer(spacing:)` is a real design parameter — one container per
  cluster. Chips 10pt apart inside a 20pt container fuse into a blob.
- There is **no Liquid Glass slider style**; the stock `Slider` *is* glass on 26.
- On iOS a background behind a `TabView` does not survive a `NavigationStack`,
  which paints the opaque system background over it.

---

## tvOS

The TV build forks the *chrome*, not the data or the player logic.

- **`.buttonStyle(.plain)` removes the focus effect on tvOS** — a focused card
  looks identical to an unfocused one and the remote appears dead. Use the
  helpers in `PlatformStyle.swift`: `cardButtonStyle()` (a lift),
  `rowButtonStyle()`, `guideBlockButtonStyle()` (an outline, because blocks sit
  shoulder-to-shoulder and a lift would overlap neighbours).
- **`.buttonStyle(.card)` is also wrong for our cards** — it wraps the label in
  its own plate and clips it, which showed as a pale border and a truncated
  channel name.
- **A pinned search field is a focus trap.** The remote catches it on every pass.
  tvOS has no header at all: `TVSidebarShell` is the navigation, and search is
  its own destination using `.searchable` + `.searchScopes`.
- `focusSection()` around each logical group, or focus lands on whatever is
  geometrically nearest.
- Overscan is real: ~5% inset (`Layout.screenMarginH/V`).
- A 1080p TV is 1920pt wide, so width-based size classes call it "expanded" —
  `guideRowCount` overrides that on TV.
- A nested style type named `Body` collides with `ButtonStyle`'s own `Body`
  associated type; name it something else.

**Verification limits:** `xcrun simctl io <udid> screenshot` gives layout, but
there is **no way to drive the remote**, so focus traversal, the card lift and
Menu-to-dismiss are all code-correct but unconfirmed. They need real hardware.

---

## State of play

**Working:** login + refresh, channel catalog, EPG guide grid, Continue Watching
carousel, category grid (`/api/channels/groups/`) opening a per-category guide
page, an iPad/Mac sidebar replacing the tab bar at regular width,
logo-derived card colours, search with scopes, playback with the
stall-timeout connect loop, custom player controls on both platforms, settings
sheet with nested navigation, tvOS sidebar navigation.

**Deliberately divergent from Flutter:**

- `formatClock` respects the system 12/24h setting instead of forcing 12-hour.
- Settings values survive reopening the sheet (Flutter's reset each push).
- Guide logo tiles are 2:1 on TV but 1.4:1 on iOS (`kGuideLogoAspect`) — a 2:1
  tile claimed 37% of a phone's width.

**Honest stubs** (render, then say "not built yet"): Favorites, Recordings, Add
playlist, Live TV / Series / Movies screens, most Advanced settings rows, the
player's favourite / multiview / PiP / overflow buttons, and the Pages menu in
the iOS header.

## Next steps

1. **Move this directory into the git repo.** It is currently untracked.
2. **Test focus traversal on real Apple TV hardware** — the one thing the
   simulator cannot verify.
3. **The player's bottom channel strip and "TV Guide" pill** from the mockup:
   an in-player channel switcher, deliberately deferred.
4. **Persist tokens** in the Keychain. `InMemoryTokenStore` means re-login every
   launch.
5. **Virtualise the guide** if channel counts grow — it is not virtualised, same
   as Flutter, and `maxRows` is what bounds the work.
6. **Wire the stubs**, starting with favourites (it appears in three places).

## Known rough edges

- Credentials live in `Local.xcconfig` → `Info.plist`, so they are readable in
  the built bundle. Same posture as `--dart-define`; a real login flow writing to
  the Keychain should replace it.
- `../soosh_viewer/env/app_settings.json` is **tracked in git with a real
  password**. Worth a `git rm --cached` plus `.gitignore`.
- The quality pill reports resolution but cannot switch it: the stream is a
  single-variant media playlist, so there is nothing to pick between.
- `Sources/Data/MockURLProtocol.swift` is yours, for previews; nothing else uses
  it yet.
- Testing against the live server burns provider connection slots —
  `/proxy/ts/stream/` returns "All active M3U profiles have reached maximum
  connection limits" after a handful of rapid launches, and needs a minute or two
  to drain. Batch player changes rather than iterating one at a time.
