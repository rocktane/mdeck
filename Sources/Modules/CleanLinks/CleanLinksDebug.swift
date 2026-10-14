import Cocoa

#if DEBUG
/// Behavioural checks for `--lifecycle-test`, and `--clean-url` for trying a link by hand.
/// Nothing here touches the general pasteboard or Tinycast: a private pasteboard and a scratch
/// file stand in for them.
enum CleanLinksDebug {
    static func builtInRules() -> ClearURLsRules? {
        guard let url = RulesStore.builtInFile, let data = try? Data(contentsOf: url) else { return nil }
        return try? ClearURLsRules(data: data)
    }

    /// `(description, passed)` for every check.
    static func verify() -> [(String, Bool)] {
        var results: [(String, Bool)] = []
        guard let rules = builtInRules() else { return [("Clean Links built-in rules load", false)] }
        results.append(("Clean Links built-in rules load (\(rules.siteCount) sites)", rules.siteCount > 100))

        let cleaner = LinkCleaner(rules: rules)
        func expect(_ input: String, _ output: String, using cleaner: LinkCleaner = cleaner, _ label: String? = nil) {
            let report = cleaner.clean(input)
            let ok = report.url == output && report.changed == (input != output)
            results.append(("clean \(label ?? input) → \(ok ? output : report.url + " (expected " + output + ")")", ok))
        }

        expect("https://example.com/article?utm_source=newsletter&utm_medium=email&id=42", "https://example.com/article?id=42")
        expect("https://example.com/?fbclid=IwAR123", "https://example.com/")
        expect("https://youtu.be/dQw4w9WgXcQ?si=abcdef", "https://youtu.be/dQw4w9WgXcQ")
        expect("https://www.youtube.com/watch?v=dQw4w9WgXcQ&si=xyz&pp=abc", "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
        expect("https://www.amazon.fr/Some-Product/dp/B0ABCDEF12/ref=sr_1_3?crid=2ABC&keywords=foo&qid=1700000000&sr=8-3&tag=blog-21",
               "https://www.amazon.fr/Some-Product/dp/B0ABCDEF12")
        expect("https://www.google.com/url?sa=t&rct=j&q=&esrc=s&url=https%3A%2F%2Fexample.com%2Fpage%3Futm_source%3Dgoogle&usg=AOv",
               "https://example.com/page")
        expect("https://l.facebook.com/l.php?u=https%3A%2F%2Fexample.org%2F%3Ffbclid%3Dabc&h=AT0", "https://example.org/")
        expect("https://eur01.safelinks.protection.outlook.com/?url=https%3A%2F%2Fexample.com%2Fa%3Futm_medium%3Demail&data=05%7C01&reserved=0",
               "https://example.com/a")
        expect("https://www.google.com/amp/s/www.theverge.com/2024/1/1/article.amp", "https://www.theverge.com/2024/1/1/article.amp")
        expect("https://www-example-com.cdn.ampproject.org/c/s/www.example.com/news/story", "https://www.example.com/news/story")
        expect("https://example.com/doc#:~:text=hello%20world", "https://example.com/doc")
        expect("https://example.com/doc#intro:~:text=x", "https://example.com/doc#intro")
        expect("https://example.com/doc#section-2", "https://example.com/doc#section-2")
        expect("https://example.com/#utm_source=x&page=2", "https://example.com/#page=2")
        expect("https://example.com/search?q=caf%C3%A9+cr%C3%A8me&utm_source=x", "https://example.com/search?q=caf%C3%A9+cr%C3%A8me")
        expect("https://x.com/user/status/123?s=20&t=abcd", "https://x.com/user/status/123")
        expect("https://www.instagram.com/p/ABC/?igsh=MWQ1ZGUxMzBkMA==", "https://www.instagram.com/p/ABC/")
        expect("https://open.spotify.com/track/123?si=abc", "https://open.spotify.com/track/123")
        expect("https://blog.example.com/post?ref=hn", "https://blog.example.com/post")
        // ClearURLs exempts GitHub from its global rules: there, ref names a branch.
        expect("https://github.com/foo/bar/tree/main?ref=dev", "https://github.com/foo/bar/tree/main?ref=dev")
        expect("https://example.com/plain/page", "https://example.com/plain/page")

        var custom = cleaner
        custom.custom = CustomRules(allowedSites: ["example.com"], keep: [ParameterRule("utm_campaign")!],
                                    remove: [ParameterRule("shop.com:aff_*")!])
        expect("https://sub.example.com/?utm_source=x", "https://sub.example.com/?utm_source=x", using: custom, "allowed site")
        expect("https://a.com/?utm_source=x&utm_campaign=y", "https://a.com/?utm_campaign=y", using: custom, "kept parameter")
        expect("https://www.shop.com/p?aff_id=3&color=red", "https://www.shop.com/p?color=red", using: custom, "site-scoped removal")
        expect("https://other.com/p?aff_id=3", "https://other.com/p?aff_id=3", using: custom, "site-scoped removal elsewhere")

        var noReferral = cleaner
        noReferral.options.referralTags = false
        expect("https://www.amazon.com/dp/B000?tag=x-20", "https://www.amazon.com/dp/B000?tag=x-20", using: noReferral, "referral tags off")
        var noTracking = cleaner
        noTracking.options.trackingParameters = false
        expect("https://a.com/?utm_source=x", "https://a.com/?utm_source=x", using: noTracking, "tracking off")
        var noRedirects = cleaner
        noRedirects.options.redirects = false
        let wrapped = noRedirects.clean("https://www.google.com/url?q=https%3A%2F%2Fexample.com%2F&sa=D")
        results.append(("redirects off keeps the wrapper", !wrapped.unwrapped && wrapped.url.hasPrefix("https://www.google.com/url?")))

        let smuggled = cleaner.clean("https://www.google.com/url?q=https%3A%2F%2Fexample.com%2F%250Aecho%2520pwned&sa=D")
        results.append(("encoded line break in a wrapped link is not unwrapped",
                        !smuggled.unwrapped && LinkCleaner.isSingleToken(smuggled.url)))
        let hosts: [(String, Bool)] = [
            ("https://bit.ly/x", true), ("https://www.amazon.fr/dp/1", true), ("http://192.168.1.1/admin", false),
            ("http://127.0.0.1:8080/", false), ("http://[::1]/", false), ("http://localhost/", false),
            ("http://nas.local/", false), ("http://router/", false), ("http://printer.home.arpa/", false),
            ("ftp://example.com/", false), ("http://2130706433/", false),
        ]
        for (url, expected) in hosts {
            results.append(("short-link hop \(url) \(expected ? "allowed" : "refused")",
                            ShortLinkResolver.isPublic(URL(string: url)) == expected))
        }

        let amazon = cleaner.clean("https://www.amazon.com/dp/B000/ref=x?tag=a-20&qid=1")
        results.append(("summary “\(amazon.summary)”", amazon.summary == "3 trackers removed"))

        let links: [(String, String?)] = [
            ("  https://a.com/x  \n", "https://a.com/x"), ("hello https://a.com", nil), ("ftp://a.com", nil),
            ("https://", nil), ("https://a.com/x y", nil),
            ("https://fr.wikipedia.org/wiki/Élysée", "https://fr.wikipedia.org/wiki/Élysée"),
        ]
        for (text, expected) in links {
            results.append(("link in “\(text.debugDescription)”", LinkCleaner.link(in: text) == expected))
        }
        results.append(("parameter rule spelling", ParameterRule(" GitHub.com : Ref ")?.entry == "github.com:ref"
                        && ParameterRule("two words") == nil && DomainList.normalize("https://www.Example.com/x") == "www.example.com"))

        results += verifyPasteboard()
        results += verifyWatcher()
        return results
    }

    private static func verifyPasteboard() -> [(String, Bool)] {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("com.yohan.mdeck.test.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let dirty = "https://example.com/a?utm_source=x&b=1"
        let clean = "https://example.com/a?b=1"
        let html = NSPasteboard.PasteboardType.html
        let title = NSPasteboard.PasteboardType("public.url-name")
        PasteboardLink.write([
            (.string, Data(dirty.utf8)), (.URL, Data(dirty.utf8)), (title, Data("A page".utf8)),
            (html, Data("<a href=\"https://example.com/a?utm_source=x&amp;b=1\">A page</a>".utf8)),
        ], to: pasteboard)
        guard let copy = PasteboardLink.read(from: pasteboard) else { return [("pasteboard link read", false)] }
        PasteboardLink.write(copy.replacing(with: clean), to: pasteboard)
        let rewritten = pasteboard.string(forType: .string) == clean && pasteboard.string(forType: .URL) == clean
            && pasteboard.string(forType: title) == "A page"
            && pasteboard.string(forType: html) == "<a href=\"https://example.com/a?b=1\">A page</a>"

        PasteboardLink.write([(.string, Data(dirty.utf8)), (.init("org.nspasteboard.ConcealedType"), Data())], to: pasteboard)
        let secretSkipped = PasteboardLink.read(from: pasteboard) == nil
        PasteboardLink.write([(.string, Data("some text, not a link".utf8))], to: pasteboard)
        let textSkipped = PasteboardLink.read(from: pasteboard) == nil
        return [("pasteboard rewrite keeps title, fixes text, URL and HTML", rewritten),
                ("pasteboard secret copy left alone", secretSkipped),
                ("pasteboard plain text left alone", textSkipped)]
    }

    /// The Tinycast path, against a scratch log and a bundle ID nothing runs under.
    private static func verifyWatcher() -> [(String, Bool)] {
        let path = NSTemporaryDirectory() + "mdeck-cleanlinks-\(UUID().uuidString).sqlite3-wal"
        FileManager.default.createFile(atPath: path, contents: Data())
        defer { try? FileManager.default.removeItem(atPath: path) }
        var signals = 0
        let watcher = ClipboardWatcher(logPath: path, bundleID: "com.yohan.mdeck.test.none") { signals += 1 }
        watcher.start()
        let polls = watcher.mode == .polling
        watcher.debugSetTinycastRunning(true)
        let attached = watcher.mode == .tinycast
        signals = 0
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(Data("frame".utf8))
            try? handle.close()
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let signalled = signals > 0
        try? FileManager.default.removeItem(atPath: path)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let fellBack = watcher.mode == .polling
        watcher.stop()
        return [("watcher polls without Tinycast", polls),
                ("watcher follows the history log while Tinycast runs", attached),
                ("watcher signals on a history write", signalled),
                ("watcher falls back to polling when the log goes", fellBack),
                ("watcher released its source, timer and observers", !watcher.hasResources)]
    }

    /// `--cleanlinks-hud <path>`: the notice, as shown after cleaning an Amazon link.
    static func snapshotHUD(to path: String) {
        let hud = CleanLinksHUD()
        hud.show(title: "Link cleaned", detail: "3 trackers removed · ⌃⌘V pastes the original")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            Debug.capture(window: hud, to: path)
            hud.dispose()
            exit(0)
        }
    }

    /// `--clean-url <url>`: prints what Clean Links would do with the link, expansion included.
    static func cleanURL(_ input: String) {
        guard let rules = builtInRules() else { print("rules unavailable"); exit(1) }
        let cleaner = LinkCleaner(rules: rules, options: CleanLinksPrefs.options, custom: CleanLinksPrefs.customRules)
        let report = cleaner.clean(input)
        print(report.url)
        print("  " + (report.changed ? report.summary : "unchanged"))
        guard let host = LinkCleaner.host(of: report.url),
              ShortLinkResolver.isShortLink(host: host, extra: CleanLinksPrefs.shortenerDomains), let url = URL(string: report.url)
        else { exit(0) }
        let resolver = ShortLinkResolver()
        resolver.resolve(url) { final in
            DispatchQueue.main.async {
                guard let final else { print("  short link did not resolve"); exit(0) }
                let expanded = cleaner.clean(final.absoluteString)
                print("expanded → \(final.absoluteString)\n\(expanded.url)\n  \(expanded.changed ? expanded.summary : "nothing more to clean")")
                exit(0)
            }
        }
    }
}
#endif
