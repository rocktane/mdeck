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

    /// `completion` runs on an arbitrary queue with the final link, or nil when the link does
    /// not redirect anywhere useful (dead link, error, timeout, a consent wall).
    func resolve(_ url: URL, completion: @escaping (URL?) -> Void) {
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
            return pending.removeValue(forKey: task.taskIdentifier)
        }
        completion?(url)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        locked { redirects[task.taskIdentifier, default: 0] += 1 }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        completionHandler(.cancel)
        let hops = locked { redirects[dataTask.taskIdentifier] ?? 0 }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard hops > 0, (200..<400).contains(status), let final = response.url,
              let scheme = final.scheme?.lowercased(), scheme == "http" || scheme == "https",
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
