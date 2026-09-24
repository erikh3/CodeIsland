import Foundation

/// Raw outcome of one HTTP exchange, before the channel interprets the body.
public struct PushTransportResponse: Equatable, Sendable {
    public var statusCode: Int?
    public var body: Data
    /// URL that finally answered, when redirects were followed.
    public var finalURL: URL?
    /// Set when no HTTP response arrived.
    public var errorDescription: String?
    /// Where the server redirected when that redirect was refused (another
    /// host, or https → http); `statusCode` is then the 3xx itself.
    public var refusedRedirect: URL?
    /// The server's `Retry-After`, in seconds, when it sent one.
    public var retryAfter: TimeInterval?

    public init(
        statusCode: Int?,
        body: Data = Data(),
        finalURL: URL? = nil,
        errorDescription: String? = nil,
        refusedRedirect: URL? = nil,
        retryAfter: TimeInterval? = nil
    ) {
        self.statusCode = statusCode
        self.body = body
        self.finalURL = finalURL
        self.errorDescription = errorDescription
        self.refusedRedirect = refusedRedirect
        self.retryAfter = retryAfter
    }
}

/// The only thing that touches the network. Tests inject a recorder, so no
/// test ever reaches a real push service.
public protocol PushTransport: Sendable {
    func send(_ request: PushHTTPRequest) async -> PushTransportResponse
}

extension PushDeliveryResult {
    /// Channel verdict for a transport outcome.
    public static func from(
        _ response: PushTransportResponse,
        kind: PushChannelKind,
        requestURL: URL
    ) -> PushDeliveryResult {
        guard let status = response.statusCode else {
            return PushDeliveryResult(ok: false, statusCode: nil, message: response.errorDescription ?? "no response")
        }
        if let refused = response.refusedRedirect {
            return PushDeliveryResult(
                ok: false,
                statusCode: status,
                message: "redirect not followed",
                redirectRefusedTo: PushRedirectPolicy.displayURL(refused)
            )
        }
        let verdict = PushResponseInterpreter.interpret(kind: kind, statusCode: status, body: response.body)
        var redirectedTo: String?
        if let finalURL = response.finalURL, finalURL != requestURL {
            redirectedTo = PushRedirectPolicy.displayURL(finalURL)
        }
        return PushDeliveryResult(ok: verdict.ok, statusCode: status, message: verdict.message, redirectedTo: redirectedTo)
    }
}

public enum PushRedirectPolicy {
    public static let maxRedirects = 5

    public enum Refusal: Equatable, Sendable {
        case tooManyHops
        case unsupportedScheme
        /// https → http: the credentials and the body would travel in clear.
        case downgrade
        /// Another host: the body still carries the Bark device key, the ntfy
        /// topic or the chat's content, and the path may be a credential.
        case otherHost

        /// Whether the user can fix it by saving the new address themselves.
        public var namesANewAddress: Bool { self == .downgrade || self == .otherHost }
    }

    /// Why a redirect from `original` to `target` is not followed; nil
    /// follows it. Only same-host hops are followed — http → https and
    /// trailing-slash or path moves, the ones a self-hosted server sends.
    public static func refusal(from original: URL?, to target: URL, redirectCount: Int) -> Refusal? {
        guard redirectCount < maxRedirects else { return .tooManyHops }
        guard let scheme = target.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
            return .unsupportedScheme
        }
        if original?.scheme?.lowercased() == "https", scheme == "http" { return .downgrade }
        if target.host?.lowercased() != original?.host?.lowercased() { return .otherHost }
        return nil
    }

    /// The request to send to a redirect target, or nil to stop.
    ///
    /// URLSession's default turns a POST answered with 301/302/303 into a
    /// body-less GET — a self-hosted Bark or ntfy behind an http→https or
    /// trailing-slash redirect then receives an empty request and the push
    /// is lost with a misleading error. Webhooks here are always a JSON POST,
    /// so method, body and headers — Authorization included, as the host
    /// never changes — are carried over.
    public static func follow(original: URLRequest, to target: URL, redirectCount: Int) -> URLRequest? {
        guard refusal(from: original.url, to: target, redirectCount: redirectCount) == nil else { return nil }
        var next = original
        next.url = target
        return next
    }

    /// Credential-free, token-free form of a URL for the settings page. The
    /// path of a webhook (Slack, Telegram) or the query (DingTalk, WeCom)
    /// *is* the credential, so only scheme, host and port are shown.
    public static func displayURL(_ url: URL) -> String {
        var parts = URLComponents()
        parts.scheme = url.scheme
        parts.host = url.host
        parts.port = url.port
        return (parts.string ?? url.absoluteString) + "/…"
    }
}

/// URLSession-backed transport: ephemeral (nothing cached or stored on disk,
/// no cookies), bounded by a whole-request timeout, redirects re-issued as
/// the same POST.
public final class URLSessionPushTransport: PushTransport {
    public static let shared = URLSessionPushTransport()

    /// Seconds for the whole exchange; a slow push server must not pile up
    /// requests behind it.
    public let timeout: TimeInterval
    private let session: URLSession

    public init(timeout: TimeInterval = 8) {
        self.timeout = timeout
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout + 2
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)
    }

    public func send(_ request: PushHTTPRequest) async -> PushTransportResponse {
        let urlRequest = request.urlRequest(timeout: timeout)
        let follower = RedirectFollower(original: urlRequest)
        do {
            let (data, response) = try await session.data(for: urlRequest, delegate: follower)
            let http = response as? HTTPURLResponse
            return PushTransportResponse(
                statusCode: http?.statusCode,
                body: data,
                finalURL: response.url,
                refusedRedirect: follower.refusedTarget,
                retryAfter: http.flatMap { Self.retryAfter($0.value(forHTTPHeaderField: "Retry-After")) }
            )
        } catch {
            return PushTransportResponse(statusCode: nil, errorDescription: error.localizedDescription)
        }
    }

    /// `Retry-After` as delay-seconds or an HTTP date.
    static func retryAfter(_ value: String?, now: Date = Date()) -> TimeInterval? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        if let seconds = TimeInterval(value) { return max(seconds, 0) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: value).map { max($0.timeIntervalSince(now), 0) }
    }

    /// Per-request delegate: counts hops, rebuilds each followed redirect,
    /// and remembers the target of one it refused.
    private final class RedirectFollower: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        private let original: URLRequest
        private let lock = NSLock()
        private var hops = 0
        private var refused: URL?

        init(original: URLRequest) {
            self.original = original
        }

        var refusedTarget: URL? { lock.withLock { refused } }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest
        ) async -> URLRequest? {
            guard let target = request.url else { return nil }
            let count = lock.withLock {
                defer { hops += 1 }
                return hops
            }
            // Relative to the hop being redirected, not the first request: a
            // same-host http → https upgrade must not make a later hop back
            // to http look like an upgrade.
            let from = response.url ?? task.currentRequest?.url ?? original.url
            if let refusal = PushRedirectPolicy.refusal(from: from, to: target, redirectCount: count) {
                if refusal.namesANewAddress { lock.withLock { refused = target } }
                return nil
            }
            return PushRedirectPolicy.follow(original: original, to: target, redirectCount: count)
        }
    }
}
