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
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'      # 77 tests
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
                      Cache/ is the SwiftData catalog cache.
Sources/Playback/     PlaybackEngine protocol, AVPlayerEngine.
                      TransportStream/ rewraps live MPEG-TS as local HLS.
Sources/Presentation/ Colour maths, logo palette, platform styles, backdrop.
Sources/Features/     One folder per screen: view + its @Observable model.
                      Multiview/ is the tile grid, owned by RootView.
                      Category/ takes HomeModel rather than owning one — a
                      second model is a second full fetch of the lineup.
Sources/App/          Entry point, RootView, the two sidebar shells.
                      SidebarDestination is shared; the chrome is not.
Tests/                77 tests: connect loop, logo palette, HLS
                      server, catalog cache, live-edge policy,
                      live-window timing, playable window, multiview.
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

## The catalog is cached in SwiftData; the guide is not

Startup used to fetch ~470KB across three endpoints every launch, and
`channels/groups` alone is **432KB of which most is discarded** — a provider
ships 1282 groups where this account renders about a dozen categories.

`CatalogCache` (`Sources/Data/Cache/`) stores channels, logos and groups, and
`HomeModel.load()` is stale-while-revalidate: paint from disk, then refresh.

**The EPG guide is deliberately not cached.** It is only 139KB and it is
perishable — programmes age out within hours, so a hit would usually be a wrong
answer needing immediate invalidation. Cache the stable thing, fetch the
perishable one.

Four decisions worth not re-litigating:

- **`@Model` types mirror the domain models rather than replacing them.**
  `Channel` stays an immutable `Sendable` struct. Model classes are reference
  types and **not `Sendable`**, and channels cross from the client actor to
  `@MainActor` on every load under `SWIFT_STRICT_CONCURRENCY: complete`. Making
  `Channel` a `@Model` means passing `PersistentIdentifier`s and re-fetching on
  the far side, everywhere. The mirror in `CachedCatalog.swift` is the price,
  and it is paid once.
- **A `@ModelActor`, not a `.modelContainer` scene modifier.** The cache lives
  under `ChannelRepository`; `Sources/Data/` has no SwiftUI imports to spend.
- **The store URL is explicit and created with `create: true`.** SwiftData
  defaults to `Library/Application Support`, and **on iOS that directory does
  not exist until something makes it** — with the default, `ModelContainer`
  fails on a fresh install and the cache silently never works.
- **Validity is keyed on `serverURL`, not age.** A different Dispatcharr means
  every id belongs to someone else's installation. There is no TTL because the
  catalog is revalidated every launch anyway; a stale lineup beats an empty
  screen while offline, and a failed refresh keeps cached content on screen
  (`refreshError`) rather than replacing it with `.failed`.

---

## Multiview

The "plus screen" control tiles the current channel and drops you back into the
app; tapping any channel after that adds it to the grid instead of opening it
full screen.

**Tiles are in-app floating windows, not system Picture in Picture.** PiP was
tried and reverted: it is a system singleton — one window per device, not one
per player — so it can host the stream you popped out and nothing else, which
makes it useless as the mechanism for a grid. The tiles are styled to read as
floating windows instead (rounded, shadowed, chrome on hover where there is a
pointer), and `AVPlayerEngine` keeps its PiP support for the player's own PiP
control.

**The pop-out hands its running player to the grid rather than building a new
one.** Constructing a fresh `PlayerModel` for the channel already on screen
opens a second upstream connection to the same stream and waits out another
join — measured before the fix as two connections and two joins for one
channel. `MultiviewModel.adopt` takes ownership, and `PlayerView.handedOff`
stops `onDisappear` from tearing down the model the tile is now playing.

**Presentation follows the count, with one exception.** One stream floats in
the corner — something you keep an eye on while using the app. Two or more takes
the screen as a grid, because at that point multiview *is* what you are doing.
The exception is `browse`, which steps aside so the next channel can be picked
without dropping to one tile; a pill in the corner says what is still playing
and leads back, because hiding the grid with no way back strands several running
streams.

Two layouts: an even grid (two side by side, four as a 2x2), and focus — one
stream at full size with the rest small along its bottom edge, over the picture
rather than beside it so the one being watched keeps the frame.

**Tile sizes are proportional to the window, not fixed points.** 240pt is a
sensible window on a phone and a postage stamp on a full-screen Mac, which is
exactly how it was reported. The corner window is 32% of the container bounded
to 300–520pt, and the focus row's tiles 20% bounded to 240–400pt — the bounds
are what keep it a window at both extremes rather than a panel or a speck.

**`MultiviewModel` is owned by `RootView`, above the navigation stack**, and
that placement is the design rather than a convenience. A tile has to keep
playing while you browse home, open a category and pick the next channel, so the
players cannot belong to any screen you can navigate away from — `PlayerView`
creates and destroys a `PlayerModel` in its `.task`, and these outlive every
view.

Three constraints shape it, and none of them are layout:

- **A tile is a whole pipeline** — an upstream connection, a rewrap session with
  its own loopback server and ~19MB window, and an `AVPlayer` decoding HD. Four
  tiles is four of everything.
- **`maxTiles` guards the provider's connection limit**, not the screen. It is
  the same limit that answers "All active M3U profiles have reached maximum
  connection limits", and exhausting it locks you out of your own service. A tap
  at the cap is refused rather than evicting a tile.
- **Exactly one tile is audible.** Four mixed audio tracks are unintelligible,
  so `setMuted` silences the rest; tapping a tile is what moves the sound.

Tapping a channel that is already tiled focuses it rather than opening a second
connection to the same stream.

**Every channel tap routes through one `open(_:)` per screen.** Multiview
changes what a tap *means*, and it has to change everywhere at once — carousel
card, guide block, search result — or the feature works on some rows and not
others.

Not built yet: expanding a tile back to full screen, moving or resizing tiles,
per-tile transport controls, and tvOS — the overlay is tap-driven with no focus
model, so on a remote the tiles would be unreachable (`onHover` is not merely
unused there, it is unavailable).

---

## Playback

**One engine, for every URL.** `AVPlayerEngine` plays everything. Live MPEG-TS
gets wrapped in HLS on the way in; nothing else is special-cased.

### The FFmpeg dependency was a misdiagnosis

This slot held three FFmpeg engines — KSPlayer, then libmpv (MPVKit), then
AetherEngine — on the premise that **AVFoundation cannot play MPEG-TS.** That
premise is wrong, and the error is worth stating precisely because it cost three
integrations and blocked Mac Catalyst three times.

AVFoundation decodes MPEG-TS natively. MPEG-TS is HLS's *original* segment
container, and these channels are ordinary H.264 High + AAC-LC — verified with
`ffprobe` against the live server. What AVFoundation cannot consume is
Dispatcharr's `/proxy/ts/stream/`: an **endless body with no duration, no index
and no segment boundaries.** Handed one it probes heavily, starts slowly and
often gives up — measured here as a failure after 27s.

So the missing piece was never a decoder. It was *framing*. Supply the
boundaries and AVFoundation does the demuxing and decoding it was always willing
to do.

### `Sources/Playback/TransportStream` — the rewrap

Three files, `Foundation` and `Network` only:

- **`TSSegmenter`** — parses 188-byte packet headers and nothing else. Reads
  PAT/PMT to find the video PID, cuts where the adaptation field sets
  `random_access_indicator`, and heads every segment with the cached PAT and PMT
  so it decodes standalone. Durations come from PCR deltas. **No elementary
  stream is ever looked at, let alone decoded.**
- **`LocalHLSServer`** — an `NWListener` bound to loopback serving a sliding-
  window live playlist (no `EXT-X-ENDLIST`) plus the segments.
- **`TSRewrapSession`** — holds the one upstream socket, feeds the segmenter,
  publishes to the server, and reconnects on drop (bounded, for the same reason
  the old `liveSourceReset` was bounded).

`AVPlayerEngine.needsRewrap(_:)` routes `/proxy/ts/` through it. Matched on the
path, not an extension: these URLs end in a channel UUID, not `.ts`.

**What this bought, beyond Catalyst:** AirPlay, PiP, Now Playing and the track
pickers are on the live path now instead of being structurally unavailable
there, so `PlayerControlsView` / `TVPlayerControlsView` no longer need forking.
Several GB of xcframeworks and the tvOS-simulator `EXCLUDED_ARCHS` workaround
are gone with it.

`PlaybackEngine` stays a protocol. Not for a second engine any more — for
`PlaybackConnectTests`, which drives the connect loop with a scripted fake and
no decoder.

### Rewrap specifics

- **A server, not an `AVAssetResourceLoaderDelegate`.** The delegate is the
  "supported" route and it is a trap for HLS: adopting it means reimplementing
  playlist fetching, live-edge tracking and reload timing by hand against an
  interface with almost no error reporting. A loopback socket lets AVFoundation
  use the HLS client Apple already ships.
- **Chunks reach the segmenter through an `AsyncStream`, never a `Task` per
  delegate callback.** Unstructured tasks are unordered, so a task per chunk
  interleaves socket reads and writes garbage into the middle of a segment.
- **A live client starts three target durations back, and the playlist must
  already contain that much.** `TSRewrapSession` waits for
  `LocalHLSServer.hasPlayableWindow` before handing the URL over. Handing over
  two segments instead — which it used to — gives AVPlayer nowhere to begin: it
  loads, waits for the window to grow, and reports no buffer or position
  movement, so `PlayerModel`'s 6s stall timeout fires and retries, and each
  retry is another upstream connection. Measured symptoms of getting this wrong:
  `-12888 Playlist File unchanged for longer than 1.5 * target duration` in the
  item's error log.
- **There is no `EXT-X-START`, and adding one back will not work.** A tag asking
  to start nearer than three target durations is rejected outright —
  `-16831 START-TIME is too close to live` — so it bought nothing and buried
  real faults in error-log noise. Join latency here is bounded below by the GOP;
  the only real fix is Low-Latency HLS.
- **The upstream runs whether or not anything is watching, so a stalled player
  falls out of the window.** Occlude the app — moving to another full-screen app
  on Catalyst is the reliable way — and the playlist keeps sliding while
  playback stands still; past the window every segment request is a 404 with no
  way back, which reads as "froze once, choppy forever". `LiveEdgePolicy` plus
  the periodic check in `AVPlayerEngine` jumps to live when the window's start
  catches up to the position. The window is 10 segments so short switches resume
  seamlessly instead of jumping.
- **AirPlay needs a LAN-reachable URL, so the server is not loopback-only.**
  AirPlay of HLS hands the *playlist URL* to the receiver, and an Apple TV
  resolving `127.0.0.1` reaches itself — measured as HTTP 200 on loopback and
  unreachable on this machine's LAN address. `LocalHLSServer` binds every
  interface and advertises the LAN address, guarded by the per-session UUID that
  every path already required. `NSLocalNetworkUsageDescription` is required with
  it.
- **Catch-up must not run while AirPlay is active, while paused, or more than
  once every few seconds.** The receiver owns the position on an external route,
  so seeking from this side knocks its timebase out — which showed as rapid
  play/pause *after* a couple of AirPlay sessions. A paused live stream falls
  behind by design, and the seek completion used to `play()` unconditionally,
  restarting playback the viewer had stopped.
- **`AVPlayerLayer.isReadyForDisplay` is the only honest "there is a picture"
  signal.** `presentationSize` going non-zero only means the *stream* declared a
  size, which happens well before anything is drawn — so audio can be running
  over a frozen or black frame while every other indicator looks healthy.
  Measured on Catalyst: first frame **3.15s** after the item starts, twice,
  to four decimal places.
- **`timeControlStatus` has three states and the UI needs all three.** Paused,
  *waiting to play at the specified rate*, and playing. Collapsing the middle
  one into "paused" put a play button over a black screen while the stream was
  still loading — and pressing it would have stopped the playback that was about
  to start. `AVPlayerEngine.isBuffering` is the third state; the controls show a
  spinner for it.
- **"It plays unless you paused it" is a single rule, not each recovery path
  remembering to resume.** Several things leave the rate at zero — an external
  route ending, a seek completing oddly, an item swap — so `playOrPause` records
  intent and the wall-clock tick restarts anything that stopped without being
  asked. Test `rate`, not `timeControlStatus`: rate is the *requested* rate and
  stays 1 while merely waiting for data, so zero means something really stopped.
- **A catch-up seek resumes unconditionally.** It used to resume only if the
  player was already `.playing`, which is the same two-states-not-three mistake:
  a correction made while buffering left the stream stopped, needing a manual
  play. A deliberate pause is excluded earlier, so by the time a seek is issued
  every remaining state means the viewer wants playback.
- **The watchdog runs on a wall clock, never on `addPeriodicTimeObserver`.**
  That observer fires on *playback time* advancing, so it falls silent exactly
  when playback stops — which is the only moment any of this matters. It
  appeared to work while our own seeks were nudging the timebase and keeping it
  alive; once the seek storm was rate-limited away, a stuck stream produced no
  catch-up, no stall report and no recovery at all. A watchdog driven by the
  thing it is watching is not a watchdog.
- **The watchdog only applies after an item has been ready once.** Before that
  the stream is merely starting, and `PlayerModel`'s connect loop owns that
  phase with its own timeout and retries; a second recovery underneath it would
  fight it and open extra upstream connections.
- **A stall watchdog backs all of this up, and is deliberately blind to the
  cause.** "Wants to play, has nothing, position not moving, for ten seconds"
  rebuilds the stream. The route-end handler covers AirPlay specifically but
  depends on a KVO firing, and the same dead end is reachable other ways — the
  window sliding past the position while something else held the player, a seek
  that landed nowhere. One rule catches all of them and needs no theory about
  which happened.
- **An ended AirPlay route rebuilds the stream rather than reviving it.**
  Reattaching the layer and calling `play()` was tried for two rounds on the
  reasoning that it costs nothing when it works — it does not work. While the
  route is external the *receiver* consumes the stream, so the local item is
  left at a position the window discarded long ago with no seekable range to
  jump to. Measured: a rebuild reaches a playable window in 0.7s when the
  upstream bursts on connect and a first frame 3.15s later, so ~4-9s total;
  letting the stall watchdog discover it costs all of that plus its ten-second
  interval. The layer is still reattached, since the replacement item draws into
  it. The layer
  is not reliably re-acquired, so the fix is to set `layer.player` again on the
  transition — **and to call `play()`, because the route also ends paused and
  nothing else restarts it.** `AVPlayerEngine.adoptVideoLayer` exists to hold the
  layer for this and for PiP. The catch-up cooldown is cleared at the same time,
  since the window slid for the whole time the picture was on the television.
- **A player whose position does not move is wedged, not lagging, and seeking
  will never fix it.** Caught from the catch-up log: the window slid from
  `96.25…107.73` to `135.15…146.64` while `currentTime()` stayed pinned at
  100.26 across eight consecutive corrections. `AVPlayerEngine` now compares the
  position against the previous correction and rebuilds the stream through
  `open()` instead of seeking again — bounded to once a minute, since a rebuild
  is another upstream connection.
- **Catch-up must not fire while the window is still filling.** A live client
  starts three target durations back, so at handover it legitimately sits near
  the start of a short window — measured as position 4.10 against `2.05…13.54`,
  which produced a jump to live in the first second of every stream. The margin
  check now requires an established window (a span of at least three margins);
  true eviction is still corrected at any size.
- **`seekableTimeRanges.end` is *not* the live edge.** A live client may not seek
  within three target durations of the end, so healthy playback sits *ahead* of
  the seekable range — measured here as `currentTime` 14.81 against `0.00…6.01`.
  A catch-up test written against `seekableEnd` as though it were the edge can
  never fire. Compare against `seekableStart` instead; that is the end eviction
  arrives from.
- **`EXT-X-TARGETDURATION` is computed from the current window, never
  ratcheted.** It was a monotonic maximum over every segment ever produced, on
  the reading that the target is a promise no segment exceeds. The promise is
  about the segments *in the playlist*, and the playlist is only this window.
  Measured cost of getting it wrong: one 8s segment raised the target from 3 to
  8 permanently, and since a live client sits three target durations back, the
  seekable span collapsed from 16s to 1s against a 25s window and stayed there.
  Playback then lived on the eviction boundary — fine for twenty minutes, then
  stuttering for good, cured only by changing channel (a new session).
  **Invariant: the window must comfortably exceed three times the longest
  segment it can hold**, which is what ties `windowSize` to
  `TSSegmenter.maxSegmentDuration`.
- **Segments are published in order, awaited inline.** Publishing through an
  unstructured `Task` is the same unordered-task hazard the `AsyncStream` avoids
  on the way in, and it applies on the way out too: two batches completing
  together can walk `EXT-X-MEDIA-SEQUENCE` backwards.
- **Bytes before the first random-access point are discarded.** We join
  mid-picture, and keeping them makes segment 0 — the one every client loads
  first — the only segment that cannot decode standalone.
- **`NSAllowsLocalNetworking`** is required in every target's Info.plist: the
  playlist is plain HTTP on 127.0.0.1 and ATS blocks cleartext by default. It
  relaxes nothing about the Dispatcharr connection, which stays HTTPS.
- **The live path must hide the navigation bar itself.** It draws its own back
  button, so without `.navigationBarBackButtonHidden` the system chevron shows up
  a few points below ours — two back buttons on screen.

`PlayerModel` is a faithful port of the stall-timeout connect loop — **do not
"simplify" it**, for the reasons in the Flutter CLAUDE.md. One thing genuinely is
simpler: Flutter needs `_openGen` *and* future-chaining to stop overlapping
connect loops; Swift's `Task` does both (cancel, then `await previous?.value`).

### Four playback bugs that cost real time

- **`automaticallyWaitsToMinimizeStalling` must stay `true`.** Setting it false
  for "start at the live edge" makes AVPlayer drop the requested rate to 0 and
  never resume: one frame on screen, `timeControlStatus == .playing`,
  `currentTime()` pinned at 0.00 forever. It hid for two rounds because
  **`AVPlayerViewController` resets this property on any player handed to it** —
  only surfaced after moving to a bare `AVPlayerLayer`.
- **`preferredForwardBufferDuration` must stay at its default of 0.** Setting it
  to 2 — "live TV would rather be two seconds behind than wait" — is smaller
  than one segment on a rewrapped playlist, and the item then **never reaches
  `.readyToPlay` at all**: status stays `.unknown`, `tracks` stays empty, and
  nothing is written to `errorLog()`. A completely silent failure, which read as
  a channel that loads forever. It hid because a bare `AVPlayer` in a
  command-line harness does not set this property, so every out-of-app
  reproduction played perfectly.
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
| Channel name's tail in the next block | Sticky header's floor ignored the leading inset |
| Live channel loads forever, no error | Playlist fine, every *segment* URI 404'd |
| Video freezes on app switch, choppy after | Player evicted from a window that kept sliding |
| Fine for 20 min, then constant stutter | One long segment ratcheted TARGETDURATION for good |
| Spinner forever, no error anywhere | Forward buffer capped below one segment |
| Rapid play/pause after AirPlaying | Catch-up seeking against the receiver's timebase |
| Repeated jumps, position never moves | Player wedged, not lagging — seeking cannot fix it |
| Black frame after AirPlay returns | Local item left at a position the window discarded |
| Play button shown while still loading | `timeControlStatus` has three states, not two |
| Loads forever after AirPlay returns | Resumed at a position the window had discarded |
| Recovers but sits paused | A correction that resumed only if already `.playing` |

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

- **Home is Continue Watching and the guide, with no Categories grid.** The grid
  is a browsing aid for a pointer; on a remote it is a wall of focus targets
  between the carousel and the guide that every trip down the page pays for, and
  the sidebar already carries the same navigation.

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
- **The backdrop is drawn once, by `TVSidebarShell`.** `AppBackground` is a
  horizontal ramp across *its own frame*, so applying it again inside `HomeView`
  gave the content a second ramp starting at the content's left edge — which is
  inset past the rail. The two met at the rail's edge and the seam read as the
  sidebar having a background of its own. `HomeView`'s copy is `#if !os(tvOS)`;
  iOS still needs it, because there a `NavigationStack` paints the opaque system
  background over anything applied outside it.
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
- **The native `Soosh-macOS` target is gone**, in favour of Catalyst. It only
  existed because Catalyst was blocked three times; dropping FFmpeg unblocked
  it, and keeping both meant two Mac apps and a set of `#if os(macOS)` branches
  that Catalyst never compiles — Catalyst is `os(iOS)`.
