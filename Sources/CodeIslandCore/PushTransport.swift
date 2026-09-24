import Foundation

/// Raw outcome of one HTTP exchange, before the channel interprets the body.
public struct PushTransportResponse: Equatable, Sendable {
    public var statusCode: Int?
    public var body: Data
    /// URL that finally answered, when redirects were followed.
    public var finalURL: URL?
    /// Set when no HTTP response arrived.
    public var errorDescription: String?

    public init(statusCode: Int?, body: Data = Data(), finalURL: URL? = nil, errorDescription: String? = nil) {
        self.statusCode = statusCode
        self.body = body
        self.finalURL = finalURL
        self.errorDescription = errorDescription
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

    /// The request to send to a redirect target, or nil to stop.
    ///
    /// URLSession's default turns a POST answered with 301/302/303 into a
    /// body-less GET — a self-hosted Bark or ntfy behind an http→https or
    /// trailing-slash redirect then receives an empty request and the push
    /// is lost with a misleading error. Webhooks here are always a JSON POST,
    /// so method, body and headers are carried over; the Authorization
    /// header only while the host stays the same, so basic-auth credentials
    /// never follow a redirect to someone else's server.
    public static func follow(original: URLRequest, to target: URL, redirectCount: Int) -> URLRequest? {
        guard redirectCount < maxRedirects,
              let scheme = target.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else { return nil }
        var next = original
        next.url = target
        if target.host?.lowercased() != original.url?.host?.lowercased() {
            next.setValue(nil, forHTTPHeaderField: "Authorization")
        }
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
            return PushTransportResponse(statusCode: http?.statusCode, body: data, finalURL: response.url)
        } catch {
            return PushTransportResponse(statusCode: nil, errorDescription: error.localizedDescription)
        }
    }

    /// Per-request delegate: counts hops and rebuilds each redirected request.
    private final class RedirectFollower: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        private let original: URLRequest
        private let lock = NSLock()
        private var hops = 0

        init(original: URLRequest) {
            self.original = original
        }

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
            return PushRedirectPolicy.follow(original: original, to: target, redirectCount: count)
        }
    }
}
