import Foundation

/// The kinds of change Clean Links may make, one settings switch each.
struct CleaningOptions {
    var trackingParameters = true
    var referralTags = true
    var pathTracking = true
    var redirects = true
    var amp = true
    var textFragments = true
}

/// The user's own rules, from the settings lists.
struct CustomRules {
    /// Domains, each covering its subdomains, whose links are never changed.
    var allowedSites: [String] = []
    var keep: [ParameterRule] = []
    var remove: [ParameterRule] = []

    func isAllowed(host: String) -> Bool {
        allowedSites.contains { DomainList.covers($0, host: host) }
    }
}

/// `utm_*` or `github.com:ref`: a parameter name, `*` matching any run of characters, optionally
/// limited to one domain and its subdomains. Names compare case-insensitively.
struct ParameterRule: Equatable {
    let domain: String?
    let name: String

    init?(_ entry: String) {
        let trimmed = entry.trimmingCharacters(in: .whitespaces).lowercased()
        if let colon = trimmed.firstIndex(of: ":") {
            let domain = DomainList.normalize(String(trimmed[..<colon]))
            let name = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard let domain, !name.isEmpty else { return nil }
            self.domain = domain
            self.name = name
        } else {
            guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace) else { return nil }
            domain = nil
            name = trimmed
        }
    }

    /// The canonical spelling shown in the list.
    var entry: String { domain.map { "\($0):\(name)" } ?? name }

    func matches(_ parameter: String, host: String) -> Bool {
        if let domain, !DomainList.covers(domain, host: host) { return false }
        return Self.glob(name, parameter.lowercased())
    }

    private static func glob(_ pattern: String, _ text: String) -> Bool {
        let parts = pattern.split(separator: "*", omittingEmptySubsequences: false).map(String.init)
        guard parts.count > 1 else { return pattern == text }
        guard text.hasPrefix(parts[0]), text.count >= parts[0].count + parts.last!.count else { return false }
        var rest = Substring(text.dropFirst(parts[0].count))
        for part in parts.dropFirst().dropLast() where !part.isEmpty {
            guard let range = rest.range(of: part) else { return false }
            rest = rest[range.upperBound...]
        }
        return rest.hasSuffix(parts.last!)
    }
}

enum DomainList {
    /// `https://www.Example.com/x` → `www.example.com`; nil for anything that is not a host name.
    static func normalize(_ entry: String) -> String? {
        var text = entry.trimmingCharacters(in: .whitespaces).lowercased()
        if let scheme = text.range(of: "://") { text = String(text[scheme.upperBound...]) }
        if let slash = text.firstIndex(where: { "/?#".contains($0) }) { text = String(text[..<slash]) }
        while text.hasPrefix(".") { text.removeFirst() }
        guard !text.isEmpty,
              text.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }) else { return nil }
        return text
    }

    static func covers(_ domain: String, host: String) -> Bool {
        let host = host.lowercased()
        return host == domain || host.hasSuffix("." + domain)
    }
}

/// What one cleaning did, for the notice and the statistics.
struct CleaningReport: Equatable {
    var url: String
    /// Query or fragment parameters removed, plus tracking segments cut from the path.
    var trackersRemoved = 0
    var unwrapped = false
    var ampRemoved = false
    var textFragmentRemoved = false
    var expanded = false

    var changed: Bool { trackersRemoved > 0 || unwrapped || ampRemoved || textFragmentRemoved || expanded }

    /// “3 trackers removed · redirect unwrapped”.
    var summary: String {
        var parts: [String] = []
        if expanded { parts.append("short link expanded") }
        if unwrapped { parts.append("redirect unwrapped") }
        if ampRemoved { parts.append("AMP removed") }
        if trackersRemoved > 0 { parts.append("\(trackersRemoved) tracker\(trackersRemoved == 1 ? "" : "s") removed") }
        if textFragmentRemoved { parts.append("highlight removed") }
        guard let first = parts.first else { return "" }
        return ([first.prefix(1).uppercased() + first.dropFirst()] + parts.dropFirst()).joined(separator: " · ")
    }

    /// Folds a later step (the expansion of a short link and its own cleaning) into this one.
    mutating func absorb(_ later: CleaningReport) {
        url = later.url
        trackersRemoved += later.trackersRemoved
        unwrapped = unwrapped || later.unwrapped
        ampRemoved = ampRemoved || later.ampRemoved
        textFragmentRemoved = textFragmentRemoved || later.textFragmentRemoved
        expanded = expanded || later.expanded
    }
}

/// The ClearURLs rule database, compiled. Immutable, so it is shared freely between the main
/// thread and the cleaning queue.
///
/// Mirrors the extension's `pureCleaning`: every provider whose URL pattern matches (and whose
/// exceptions do not) contributes its redirections, raw rules and parameter rules, and the whole
/// pass repeats until the link stops changing. A rule is a regular expression matched against
/// the entire parameter name, case-insensitively.
final class ClearURLsRules {
    struct Provider {
        let name: String
        let pattern: NSRegularExpression
        let exceptions: [NSRegularExpression]
        let redirections: [NSRegularExpression]
        let rawRules: [NSRegularExpression]
        let rules: [NSRegularExpression]
        let referral: [NSRegularExpression]
    }

    enum LoadError: Error { case malformed, tooSmall }

    let providers: [Provider]
    /// Sites with rules of their own, not counting mdeck's additions; shown in the settings.
    let siteCount: Int

    init(data: Data) throws {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = root["providers"] as? [String: [String: Any]] else { throw LoadError.malformed }
        // A truncated or hijacked download must not replace a working database.
        guard entries.count >= 50, entries["globalRules"] != nil else { throw LoadError.tooSmall }
        var providers = entries.sorted { $0.key < $1.key }.compactMap { Self.provider(named: $0.key, $0.value) }
        providers += Self.additions.compactMap { Self.provider(named: $0.name, $0.entry) }
        self.providers = providers
        siteCount = entries.count - 1
    }

    private static func provider(named name: String, _ entry: [String: Any]) -> Provider? {
        // Providers that block a whole domain are for a browser's requests, not for links.
        guard entry["completeProvider"] as? Bool != true,
              let patternText = entry["urlPattern"] as? String,
              let pattern = regex(patternText) else { return nil }
        func list(_ key: String, anchored: Bool = false) -> [NSRegularExpression] {
            ((entry[key] as? [String]) ?? []).compactMap { regex(anchored ? "^(?:\($0))$" : $0) }
        }
        return Provider(name: name, pattern: pattern, exceptions: list("exceptions"),
                        redirections: list("redirections"), rawRules: list("rawRules"),
                        rules: list("rules", anchored: true), referral: list("referralMarketing", anchored: true))
    }

    private static func regex(_ pattern: String) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    /// mdeck's own additions, in ClearURLs' format: trackers and wrappers it does not cover yet.
    private static let additions: [(name: String, entry: [String: Any])] = [
        ("mdeck global", [
            "urlPattern": ".*",
            "rules": ["gbraid", "wbraid", "ttclid", "li_fat_id", "epik", "irclickid", "_kx", "s_kwcid",
                      "ef_id", "_hsmi", "igshid", "rdt_cid", "sc_cid", "mkt_tok"],
        ]),
        ("mdeck x.com", [
            "urlPattern": "^https?:\\/\\/(?:[a-z0-9-]+\\.)*?x\\.com",
            "rules": ["(?:ref_?)?src", "s", "t", "cn", "ref_url"],
        ]),
        ("mdeck linkedin", [
            "urlPattern": "^https?:\\/\\/(?:[a-z0-9-]+\\.)*?linkedin\\.com",
            "rules": ["trk", "trk_?info", "trackingId", "lipi", "midToken", "midSig", "trkEmail", "refId",
                      "originalSubdomain", "rcm"],
            "redirections": ["^https?:\\/\\/(?:[a-z0-9-]+\\.)*?linkedin\\.com\\/redir\\/redirect.*?[?&]url=([^&]*)"],
        ]),
        ("mdeck safelinks", [
            "urlPattern": "^https?:\\/\\/(?:[a-z0-9-]+\\.)*?safelinks\\.protection\\.outlook\\.com",
            "redirections": ["^https?:\\/\\/(?:[a-z0-9-]+\\.)*?safelinks\\.protection\\.outlook\\.com\\/.*?[?&]url=([^&]*)"],
        ]),
        ("mdeck slack", [
            "urlPattern": "^https?:\\/\\/slack-redir\\.net",
            "redirections": ["^https?:\\/\\/slack-redir\\.net\\/link.*?[?&]url=([^&]*)"],
        ]),
        ("mdeck threads", [
            "urlPattern": "^https?:\\/\\/l\\.threads\\.(?:net|com)",
            "redirections": ["^https?:\\/\\/l\\.threads\\.(?:net|com)\\/.*?[?&]u=([^&]*)"],
        ]),
    ]

    func matching(_ url: String) -> [Provider] {
        let range = NSRange(url.startIndex..., in: url)
        return providers.filter { provider in
            provider.pattern.firstMatch(in: url, range: range) != nil
                && !provider.exceptions.contains { $0.firstMatch(in: url, range: range) != nil }
        }
    }
}

/// Cleans one link. Pure: the same input, rules and settings always give the same output, and
/// nothing here touches the network, the pasteboard or the preferences.
struct LinkCleaner {
    let rules: ClearURLsRules?
    var options = CleaningOptions()
    var custom = CustomRules()

    /// The link alone in a pasteboard string: `http(s)://host…`, no whitespace inside. Nil for
    /// anything else, which is then left alone.
    static func link(in text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= 8192, !trimmed.contains(where: \.isWhitespace),
              let host = host(of: trimmed), !host.isEmpty else { return nil }
        return trimmed
    }

    /// Nil unless the string is an http(s) URL. Tolerates the unencoded characters (accents,
    /// spaces in fragments…) that browsers put in copied links.
    static func host(of url: String) -> String? {
        let lower = url.lowercased()
        guard lower.hasPrefix("http://") || lower.hasPrefix("https://") else { return nil }
        let components = URLComponents(string: url)
            ?? url.addingPercentEncoding(withAllowedCharacters: .urlAllowed).flatMap(URLComponents.init(string:))
        guard let host = components?.host, !host.isEmpty else { return nil }
        return host.lowercased()
    }

    func clean(_ input: String) -> CleaningReport {
        var report = CleaningReport(url: input)
        // Each pass can uncover more to clean (an unwrapped redirect is a new link); stop when
        // a pass changes nothing, with a bound in case two rules ever undo each other.
        for _ in 0..<8 {
            let before = report.url
            pass(&report)
            if report.url == before { break }
        }
        return report
    }

    private func pass(_ report: inout CleaningReport) {
        guard let host = Self.host(of: report.url), !custom.isAllowed(host: host) else { return }

        if options.amp, let original = Self.ampOriginal(of: report.url) {
            report.url = original
            report.ampRemoved = true
            return
        }

        let providers = rules?.matching(report.url) ?? []

        if options.redirects {
            for provider in providers {
                for redirection in provider.redirections {
                    if let target = Self.capture(redirection, in: report.url), target != report.url {
                        report.url = target
                        report.unwrapped = true
                        return
                    }
                }
            }
        }

        if options.pathTracking {
            for provider in providers {
                for raw in provider.rawRules {
                    var parts = URLParts(report.url)
                    let range = NSRange(parts.base.startIndex..., in: parts.base)
                    let count = raw.numberOfMatches(in: parts.base, range: range)
                    guard count > 0 else { continue }
                    parts.base = raw.stringByReplacingMatches(in: parts.base, range: range, withTemplate: "")
                    report.url = parts.joined
                    report.trackersRemoved += count
                }
            }
        }

        var patterns: [NSRegularExpression] = []
        for provider in providers {
            if options.trackingParameters { patterns += provider.rules }
            if options.referralTags { patterns += provider.referral }
        }
        let shouldRemove: (String, String) -> Bool = { raw, decoded in
            if self.custom.keep.contains(where: { $0.matches(decoded, host: host) || $0.matches(raw, host: host) }) {
                return false
            }
            if self.custom.remove.contains(where: { $0.matches(decoded, host: host) || $0.matches(raw, host: host) }) {
                return true
            }
            return patterns.contains { Self.fullMatch($0, raw) || Self.fullMatch($0, decoded) }
        }

        var parts = URLParts(report.url)
        if let query = parts.query {
            let (kept, removed) = Self.filter(query, shouldRemove)
            if removed > 0 {
                parts.query = kept.isEmpty ? nil : kept
                report.trackersRemoved += removed
            }
        }
        if var fragment = parts.fragment {
            if options.textFragments, let directive = fragment.range(of: ":~:") {
                fragment = String(fragment[..<directive.lowerBound])
                report.textFragmentRemoved = true
            }
            // Some trackers ride in the fragment (`#utm_source=…`); only a fragment shaped like
            // parameters is treated as such, never an anchor.
            if fragment.contains("=") {
                let (kept, removed) = Self.filter(fragment, shouldRemove)
                if removed > 0 {
                    fragment = kept
                    report.trackersRemoved += removed
                }
            }
            parts.fragment = fragment.isEmpty ? nil : fragment
        }
        report.url = parts.joined
    }

    /// `a=1&utm_source=x&b` → `a=1&b`, keeping the kept parameters exactly as they were written.
    private static func filter(_ list: String, _ shouldRemove: (String, String) -> Bool) -> (String, Int) {
        var removed = 0
        let kept = list.split(separator: "&", omittingEmptySubsequences: true).filter { pair in
            let raw = String(pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)[0])
            let decoded = raw.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? raw
            if shouldRemove(raw, decoded) { removed += 1; return false }
            return true
        }
        return (kept.joined(separator: "&"), removed)
    }

    private static func fullMatch(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// The first capture group, percent-decoded until stable, if it is an http(s) link.
    private static func capture(_ regex: NSRegularExpression, in url: String) -> String? {
        guard let match = regex.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)),
              match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: url) else { return nil }
        var target = String(url[range])
        for _ in 0..<5 {
            guard let decoded = target.removingPercentEncoding, decoded != target else { break }
            target = decoded
        }
        return host(of: target) == nil ? nil : target
    }

    /// Google's AMP viewer and the AMP cache serve a publisher's page under their own address;
    /// both spell the original out in the path.
    private static let ampPatterns = [
        "^https?://(?:www\\.)?google\\.[a-z.]+/amp/(s/)?([^?#]+.*)$",
        "^https?://[a-z0-9-]+\\.cdn\\.ampproject\\.org/[a-z]+/(s/)?([^?#]+.*)$",
    ].map { try! NSRegularExpression(pattern: $0, options: .caseInsensitive) }

    static func ampOriginal(of url: String) -> String? {
        for regex in ampPatterns {
            guard let match = regex.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)),
                  let rest = Range(match.range(at: 2), in: url) else { continue }
            let secure = match.range(at: 1).location != NSNotFound
            let candidate = (secure ? "https://" : "http://") + url[rest]
            if host(of: candidate) != nil { return candidate }
        }
        return nil
    }
}

/// A link split at its first `#` and the first `?` before it, so each part can be edited and
/// put back without re-encoding anything.
private struct URLParts {
    var base: String
    var query: String?
    var fragment: String?

    init(_ url: String) {
        var rest = Substring(url)
        if let hash = rest.firstIndex(of: "#") {
            fragment = String(rest[rest.index(after: hash)...])
            rest = rest[..<hash]
        }
        if let question = rest.firstIndex(of: "?") {
            query = String(rest[rest.index(after: question)...])
            rest = rest[..<question]
        }
        base = String(rest)
    }

    var joined: String {
        var url = base
        if let query, !query.isEmpty { url += "?" + query }
        if let fragment, !fragment.isEmpty { url += "#" + fragment }
        return url
    }
}

private extension CharacterSet {
    /// Everything that may stay as is in a URL; the rest is percent-encoded for parsing only.
    static let urlAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.formUnion(.urlPathAllowed)
        set.formUnion(.urlFragmentAllowed)
        set.insert(charactersIn: "#%")
        return set
    }()
}
