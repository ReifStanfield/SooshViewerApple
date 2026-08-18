import Foundation
import os
import SwiftData

/// Disk cache for the channel catalog.
///
/// **A `@ModelActor`, not a `ModelContainer` handed to a SwiftUI scene.**
/// `Sources/Data/` has no SwiftUI imports and should not gain one for this —
/// the cache belongs under `ChannelRepository`, not beside the view tree. The
/// macro gives this actor its own `ModelContext` on its own executor, which is
/// the supported way to touch SwiftData off the main actor under Swift 6.
///
/// It converts at the boundary in both directions: `@Model` objects never
/// escape this actor, and `ChannelCatalog` — a `Sendable` value — is what
/// crosses back out.
///
/// **Every operation here is best-effort.** A cache that throws is a cache that
/// takes the app down with it; the network path is the source of truth and this
/// one only ever makes startup faster. Failures are logged and swallowed.
@ModelActor
actor CatalogCache {
    private static let log = Logger(subsystem: "com.soosh.viewer", category: "CatalogCache")

    /// Opens the on-disk store, or returns nil if it cannot be opened.
    ///
    /// Nil rather than throwing: every caller's correct response to a broken
    /// cache is to carry on without one, so there is nothing useful to do with
    /// an error and no reason to make each call site say so.
    static func makeDefault() -> CatalogCache? {
        do {
            // **The store URL is explicit, and the `create: true` is the point.**
            //
            // SwiftData's default store lives in `Library/Application Support`,
            // and on iOS **that directory does not exist until something makes
            // it** — a fresh install has `Library/` but not this. Left to the
            // default, `ModelContainer` fails with "Sandbox access to
            // file-write-create denied" (really just errno 2), `makeDefault`
            // returns nil, and the cache silently never works on exactly the
            // installs it was built for. Caught here because the test host hit
            // it and logged it.
            let support = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let configuration = ModelConfiguration(url: support.appending(path: "catalog.store"))
            let container = try ModelContainer(
                for: CachedChannel.self, CachedLogo.self, CachedGroup.self, CatalogStamp.self,
                configurations: configuration
            )
            return CatalogCache(modelContainer: container)
        } catch {
            log.error("could not open catalog cache: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Reading

    /// The stored catalog, or nil when there is nothing usable on disk.
    func load() -> ChannelCatalog? {
        do {
            guard let stamp = try modelContext.fetch(FetchDescriptor<CatalogStamp>()).first else {
                return nil
            }
            guard stamp.serverURL == AppConfig.baseURL else {
                Self.log.notice("cached catalog belongs to a different server, discarding")
                clear()
                return nil
            }

            let channels = try modelContext.fetch(FetchDescriptor<CachedChannel>())
            // An empty cache is not a cache hit. Returning an empty catalog here
            // would paint an empty home screen and call it loaded.
            guard !channels.isEmpty else { return nil }

            let logos = try modelContext.fetch(FetchDescriptor<CachedLogo>())
            let groups = try modelContext.fetch(FetchDescriptor<CachedGroup>())

            // `ChannelCatalog.init` recomputes `visibleChannels` and
            // `categories`, so the derived data is never persisted — only the
            // three lists it derives from. One less thing to keep in sync.
            return ChannelCatalog(
                channels: channels.map(\.channel),
                logosByID: Dictionary(
                    logos.map { ($0.id, $0.logo) },
                    uniquingKeysWith: { _, last in last }
                ),
                groups: groups.map(\.group)
            )
        } catch {
            Self.log.error("could not read catalog cache: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Writing

    /// Replaces the stored catalog wholesale.
    ///
    /// **Replace-all rather than a diff.** The catalog arrives as a complete
    /// snapshot from three endpoints, so there is no delta to apply — and a
    /// merge would have to decide what a *missing* channel means, which is
    /// exactly the case (a removed channel) where getting it wrong leaves a
    /// dead row on the home screen forever.
    func save(_ catalog: ChannelCatalog) {
        do {
            clear()
            for channel in catalog.channels { modelContext.insert(CachedChannel(channel)) }
            for logo in catalog.logosByID.values { modelContext.insert(CachedLogo(logo)) }
            for group in catalog.groups { modelContext.insert(CachedGroup(group)) }
            modelContext.insert(CatalogStamp(serverURL: AppConfig.baseURL))
            try modelContext.save()
            Self.log.debug("cached \(catalog.channels.count) channels, \(catalog.groups.count) groups")
        } catch {
            Self.log.error("could not write catalog cache: \(error.localizedDescription)")
        }
    }

    private func clear() {
        try? modelContext.delete(model: CachedChannel.self)
        try? modelContext.delete(model: CachedLogo.self)
        try? modelContext.delete(model: CachedGroup.self)
        try? modelContext.delete(model: CatalogStamp.self)
    }
}
