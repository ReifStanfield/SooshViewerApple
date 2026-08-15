import Foundation

/// Thrown for any non-2xx response, plus the shapes that mean the server sent
/// something we cannot read.
enum APIError: Error, LocalizedError {
    case http(status: Int, path: String, body: String)
    case notConfigured
    case unreadableList(path: String)

    var isUnauthorized: Bool {
        if case .http(401, _, _) = self { return true }
        return false
    }

    var errorDescription: String? {
        switch self {
        case .http(let status, let path, _): return "HTTP \(status) at \(path)"
        case .notConfigured: return "No server configured."
        case .unreadableList(let path): return "Unexpected list shape from \(path)."
        }
    }
}

/// Where the JWT pair lives between requests.
///
/// Deliberately a protocol: the default is memory-only, so tokens are lost on
/// restart. Swap in a Keychain-backed implementation to persist them — these
/// are credentials, so `UserDefaults` is not an option.
protocol TokenStore: Actor {
    var accessToken: String? { get }
    var refreshToken: String? { get }
    func save(access: String, refresh: String)
    func clear()
}

actor InMemoryTokenStore: TokenStore {
    private(set) var accessToken: String?
    private(set) var refreshToken: String?

    func save(access: String, refresh: String) {
        accessToken = access
        refreshToken = refresh
    }

    func clear() {
        accessToken = nil
        refreshToken = nil
    }
}

/// HTTP client for the Dispatcharr API.
///
/// An `actor`, not a class. Access tokens expire after 30 minutes, so a 401
/// triggers one refresh-and-retry — and ten concurrent 401s must trigger *one*
/// refresh, not ten. Actor isolation gives that guarantee for free where the
/// Dart version needed a hand-rolled single-flight future.
actor DispatcharrClient {
    let baseURL: String
    private let tokens: any TokenStore
    private let session: URLSession

    /// The in-flight refresh, if any. Concurrent callers await this same Task
    /// instead of starting their own.
    private var refreshTask: Task<Void, any Error>?

    init(
        baseURL: String,
        tokens: any TokenStore = InMemoryTokenStore(),
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        self.tokens = tokens
        self.session = session
    }

    var isAuthenticated: Bool {
        get async { await tokens.accessToken != nil }
    }

    /// The playback URL for a channel.
    ///
    /// Takes the channel **UUID**, not the numeric id: the proxy route types its
    /// path parameter as a UUID converter, whereas the REST routes type it as
    /// `integer`. Passing the numeric id yields
    /// `404 No Stream matches the given query.`
    ///
    /// The route says `ts` but this deployment answers with an `.m3u8` — do not
    /// infer the container format from the path.
    nonisolated func streamURL(forChannelUUID uuid: String) -> URL? {
        URL(string: "\(baseURL)/proxy/ts/stream/\(uuid)")
    }

    // MARK: - Auth

    /// `POST /api/accounts/token/` — exchanges credentials for a token pair.
    func login(username: String, password: String) async throws {
        let body = ["username": username, "password": password]
        let data = try await sendRaw(
            method: "POST",
            url: try url(path: "/api/accounts/token/"),
            body: body,
            allowRetry: false
        )
        let pair = try JSONDecoder().decode(TokenPair.self, from: data)
        await tokens.save(access: pair.access, refresh: pair.refresh ?? "")
    }

    func logout() async {
        await tokens.clear()
    }

    private struct TokenPair: Decodable {
        let access: String
        let refresh: String?
    }

    /// `POST /api/accounts/token/refresh/`, single-flight.
    ///
    /// The response always carries a new access token; some deployments rotate
    /// the refresh token too, so the old one is kept when absent.
    private func refresh() async throws {
        if let refreshTask {
            return try await refreshTask.value
        }
        let task = Task<Void, any Error> { [tokens, session] in
            guard let stored = await tokens.refreshToken, !stored.isEmpty else {
                throw APIError.http(status: 401, path: "refresh", body: "No refresh token.")
            }
            var request = URLRequest(url: try self.url(path: "/api/accounts/token/refresh/"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(["refresh": stored])

            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else {
                await tokens.clear()
                throw APIError.http(
                    status: status,
                    path: "/api/accounts/token/refresh/",
                    body: "Refresh failed; login required."
                )
            }
            let pair = try JSONDecoder().decode(TokenPair.self, from: data)
            await tokens.save(access: pair.access, refresh: pair.refresh ?? stored)
        }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }

    // MARK: - Requests

    private nonisolated func url(
        path: String,
        query: [String: String?] = [:]
    ) throws -> URL {
        guard var components = URLComponents(string: baseURL + path) else {
            throw APIError.notConfigured
        }
        let items = query.compactMap { key, value in
            value.map { URLQueryItem(name: key, value: $0) }
        }
        if !items.isEmpty { components.queryItems = items.sorted { $0.name < $1.name } }
        guard let url = components.url else { throw APIError.notConfigured }
        return url
    }

    private func sendRaw(
        method: String,
        url: URL,
        body: (any Encodable)? = nil,
        allowRetry: Bool = true
    ) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let access = await tokens.accessToken {
            request.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.httpBody = try JSONEncoder().encode(AnyEncodable(body))
        }

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0

        if status == 401, allowRetry, await tokens.refreshToken != nil {
            try await refresh()
            return try await sendRaw(method: method, url: url, body: body, allowRetry: false)
        }
        guard (200..<300).contains(status) else {
            throw APIError.http(
                status: status,
                path: url.path,
                body: String(data: data, encoding: .utf8) ?? ""
            )
        }
        return data
    }

    /// Decodes a list endpoint, unwrapping whichever envelope arrives.
    func getList<T: Decodable & Sendable>(
        _ path: String,
        as type: T.Type = T.self,
        query: [String: String?] = [:]
    ) async throws -> [T] {
        let data = try await sendRaw(method: "GET", url: try url(path: path, query: query))
        guard let items = try? JSONDecoder().decode(ListEnvelope<T>.self, from: data) else {
            // Deliberately an error, not an empty array. An earlier Flutter
            // version returned [] here and the guide silently showed nothing
            // for days.
            throw APIError.unreadableList(path: path)
        }
        return items.items
    }

    /// Fetches a DRF-paginated list, following `next` until exhausted.
    ///
    /// `maxPages` is a safety valve — a large channel list is fine, an unbounded
    /// loop against a misbehaving server is not.
    func getAllPages<T: Decodable & Sendable>(
        _ path: String,
        as type: T.Type = T.self,
        query: [String: String?] = [:],
        pageSize: Int = 250,
        maxPages: Int = 200
    ) async throws -> [T] {
        var collected: [T] = []
        var query = query
        query["page_size"] = String(pageSize)
        var next: URL? = try url(path: path, query: query)

        var page = 0
        while let current = next, page < maxPages {
            page += 1
            let data = try await sendRaw(method: "GET", url: current)

            // A paginated body has `results` + `next`. Anything else (bare
            // array, or a `data` envelope) has no next link: take it whole.
            if let paged = try? JSONDecoder().decode(Paginated<T>.self, from: data) {
                collected.append(contentsOf: paged.results)
                next = paged.next.flatMap(URL.init(string:))
                continue
            }
            guard let envelope = try? JSONDecoder().decode(ListEnvelope<T>.self, from: data)
            else {
                throw APIError.unreadableList(path: path)
            }
            collected.append(contentsOf: envelope.items)
            next = nil
        }
        return collected
    }
}

/// Pulls the array out of the three envelope shapes this API uses.
///
/// Endpoints are inconsistent: DRF list views paginate with `results`,
/// `/api/epg/grid/` wraps in `data` (undocumented — the OpenAPI schema declares
/// a bare array), and some return the array directly.
private struct ListEnvelope<T: Decodable>: Decodable {
    let items: [T]

    private enum CodingKeys: String, CodingKey { case data, results }

    init(from decoder: any Decoder) throws {
        if let bare = try? decoder.singleValueContainer().decode([T].self) {
            items = bare
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let data = try? container.decode([T].self, forKey: .data) {
            items = data
        } else {
            items = try container.decode([T].self, forKey: .results)
        }
    }
}

private struct Paginated<T: Decodable>: Decodable {
    let results: [T]
    let next: String?
}

/// Type-erasing shim so `sendRaw` can take `any Encodable`.
private struct AnyEncodable: Encodable {
    private let encode: (any Encoder) throws -> Void
    init(_ wrapped: any Encodable) {
        encode = { encoder in try wrapped.encode(to: encoder) }
    }
    func encode(to encoder: any Encoder) throws { try encode(encoder) }
}
