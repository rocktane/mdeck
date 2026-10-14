import Foundation

/// Follows a short link (bit.ly, t.co…) to where it leads, without loading the page.
///
/// One GET per link, through an ephemeral session: no cookies, no cache, no credentials. The
/// request follows the redirects, and is cancelled as soon as the final response's headers
/// arrive, so no body is downloaded. The shortening service does learn that the link was
/// resolved — that is the trade-off the user opts into with “Expand short links”.
final class ShortLinkResolver: NSObject, URLSessionDataDelegate {
    /// Built-in shorteners; the user adds more in the settings.
    static let builtInDomains = [
        "bit.ly", "bitly.com", "t.co", "tinyurl.com", "ow.ly", "buff.ly", "lnkd.in", "amzn.to", "amzn.eu",
        "a.co", "maps.app.goo.gl", "goo.gl", "rebrand.ly", "is.gd", "v.gd", "cutt.ly", "shorturl.at",
        "t.ly", "tiny.cc", "rb.gy", "bl.ink", "s.id", "trib.al", "dlvr.it", "fb.me", "ift.tt", "spoti.fi",
        "apple.co", "redd.it", "aka.ms", "wp.me", "flip.it", "qr.ae", "share.google", "on.soundcloud.com",
        "pin.it", "vm.tiktok.com", "vt.tiktok.com", "msft.it", "tr.ee",
    ]

    static let timeout: TimeInterval = 3

    private var session: URLSession?
    private var pending: [Int: (URL?) -> Void] = [:]
    private var redirects: [Int: Int] = [:]
    /// Tasks whose redirect chain tried to leave the public internet.
    private var blocked: Set<Int> = []
    private let lock = NSLock()

    var hasPendingWork: Bool { locked { !pending.isEmpty } }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    static func isShortLink(host: String, extra: [String]) -> Bool {
        (builtInDomains + extra).contains { DomainList.covers($0, host: host) }
    }

    /// Copying a link must never make mdeck send a request into the local network (a router's
    /// admin page, a NAS…): every hop of a resolution has to be an http(s) URL on a public-
    /// looking host name. IP literals, single-label names and local suffixes are refused.
    static func isPublic(_ url: URL?) -> Bool {
        guard let url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")),
              host.contains("."), !host.contains(":") else { return false }
        if host.split(separator: ".").allSatisfy({ $0.allSatisfy(\.isNumber) }) { return false }
        let local = ["localhost", "local", "localdomain", "internal", "intranet", "lan", "home", "corp",
                     "home.arpa", "in-addr.arpa", "ip6.arpa"]
        return !local.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// `completion` runs on an arbitrary queue with the final link, or nil when the link does
    /// not redirect anywhere useful (dead link, error, timeout, a consent wall).
    func resolve(_ url: URL, completion: @escaping (URL?) -> Void) {
        guard Self.isPublic(url) else { return completion(nil) }
        let session = self.session ?? makeSession()
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: Self.timeout)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        let task = session.dataTask(with: request)
        locked {
            pending[task.taskIdentifier] = completion
            redirects[task.taskIdentifier] = 0
        }
        task.resume()
    }

    /// Cancels every request; their completions are dropped, not called.
    func cancelAll() {
        locked {
            pending.removeAll()
            redirects.removeAll()
            blocked.removeAll()
        }
        session?.invalidateAndCancel()
        session = nil
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = Self.timeout
        configuration.timeoutIntervalForResource = Self.timeout
        configuration.httpMaximumConnectionsPerHost = 2
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        self.session = session
        return session
    }

    private func finish(_ task: URLSessionTask, _ url: URL?) {
        let completion = locked { () -> ((URL?) -> Void)? in
            redirects[task.taskIdentifier] = nil
            blocked.remove(task.taskIdentifier)
            return pending.removeValue(forKey: task.taskIdentifier)
        }
        completion?(url)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard Self.isPublic(request.url) else {
            locked { _ = blocked.insert(task.taskIdentifier) }
            return completionHandler(nil)
        }
        locked { redirects[task.taskIdentifier, default: 0] += 1 }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        completionHandler(.cancel)
        let (hops, wasBlocked) = locked { (redirects[dataTask.taskIdentifier] ?? 0, blocked.contains(dataTask.taskIdentifier)) }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard !wasBlocked, hops > 0, (200..<400).contains(status), let final = response.url, Self.isPublic(final),
              let host = final.host?.lowercased(), !host.hasPrefix("consent."),
              final != dataTask.originalRequest?.url
        else { return finish(dataTask, nil) }
        finish(dataTask, final)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // Reached when the request failed before any response (or after our own cancel, by
        // which point the completion is already gone).
        finish(task, nil)
    }
}
