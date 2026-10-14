import Foundation
import CryptoKit

/// Where Clean Links' ClearURLs rules come from, and keeping them current.
///
/// The app ships a copy (`Contents/Resources/clearurls.json`). Once a week while the module
/// runs, the hash published next to the official database is compared with the installed one;
/// when it differs, the database is downloaded, checked against that SHA-256, parsed, and only
/// then saved to `~/Library/Application Support/mdeck/CleanLinks/clearurls.json` and swapped in.
/// Any failure keeps the rules in use.
final class RulesStore {
    static let dataURL = URL(string: "https://rules2.clearurls.xyz/data.minify.json")!
    static let hashURL = URL(string: "https://rules2.clearurls.xyz/rules.minify.hash")!
    static let updateInterval: TimeInterval = 7 * 24 * 3600
    /// After a failed attempt (offline…), try again this much later rather than every hour.
    static let retryInterval: TimeInterval = 6 * 3600

    enum Source { case builtIn, downloaded }

    private(set) var rules: ClearURLsRules?
    private(set) var source: Source = .builtIn
    private(set) var isUpdating = false
    /// Called on the main thread whenever the rules or their status change.
    var onChange: (() -> Void)?

    private let queue = DispatchQueue(label: "mdeck.cleanlinks.rules", qos: .utility)
    private var session: URLSession?
    private var generation = 0

    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("mdeck/CleanLinks", isDirectory: true)
    }
    static var downloadedFile: URL { directory.appendingPathComponent("clearurls.json") }
    static var builtInFile: URL? { Bundle.main.url(forResource: "clearurls", withExtension: "json") }

    var hasPendingWork: Bool { isUpdating || session != nil }

    // MARK: - Loading

    /// Compiles the rules off the main thread; the downloaded copy wins when it is valid.
    func load() {
        generation += 1
        let token = generation
        queue.async { [weak self] in
            var loaded: (ClearURLsRules, Source)?
            if let data = try? Data(contentsOf: Self.downloadedFile), let rules = try? ClearURLsRules(data: data) {
                loaded = (rules, .downloaded)
            } else if let url = Self.builtInFile, let data = try? Data(contentsOf: url),
                      let rules = try? ClearURLsRules(data: data) {
                loaded = (rules, .builtIn)
            }
            DispatchQueue.main.async {
                guard let self, self.generation == token, let loaded else { return }
                self.rules = loaded.0
                self.source = loaded.1
                self.onChange?()
            }
        }
    }

    /// Stops any download and forgets the compiled rules; a late result is ignored.
    func unload() {
        generation += 1
        session?.invalidateAndCancel()
        session = nil
        isUpdating = false
        queue.sync {}
        rules = nil
    }

    // MARK: - Updating

    var isUpdateDue: Bool {
        let now = Date().timeIntervalSince1970
        return now - CleanLinksPrefs.rulesCheckedAt >= Self.updateInterval
            && now - CleanLinksPrefs.rulesAttemptedAt >= Self.retryInterval
    }

    func update() {
        guard !isUpdating else { return }
        isUpdating = true
        onChange?()

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 60
        let session = URLSession(configuration: configuration)
        self.session = session
        let token = generation

        session.dataTask(with: Self.hashURL) { [weak self] data, response, error in
            let published = data.flatMap { String(data: $0, encoding: .utf8) }?
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard let published, published.count == 64, published.allSatisfy(\.isHexDigit),
                  (response as? HTTPURLResponse)?.statusCode == 200 else {
                self?.finish(token, .failed(error?.localizedDescription ?? "The rules server did not answer."))
                return
            }
            if published == CleanLinksPrefs.rulesHash, FileManager.default.fileExists(atPath: Self.downloadedFile.path) {
                self?.finish(token, .unchanged)
                return
            }
            session.dataTask(with: Self.dataURL) { data, response, error in
                self?.finish(token, Self.install(data, response, error, expecting: published))
            }.resume()
        }.resume()
    }

    private enum Outcome {
        case unchanged
        case updated(ClearURLsRules, hash: String)
        case failed(String)
    }

    /// Verifies, compiles and saves a downloaded database. Runs on the session's queue.
    private static func install(_ data: Data?, _ response: URLResponse?, _ error: Error?,
                                expecting hash: String) -> Outcome {
        guard let data, (response as? HTTPURLResponse)?.statusCode == 200 else {
            return .failed(error?.localizedDescription ?? "The download failed.")
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == hash else { return .failed("The download did not match its published checksum.") }
        guard let rules = try? ClearURLsRules(data: data) else { return .failed("The downloaded rules could not be read.") }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: downloadedFile, options: .atomic)
        } catch {
            return .failed("The rules could not be saved.")
        }
        return .updated(rules, hash: hash)
    }

    private func finish(_ token: Int, _ outcome: Outcome) {
        DispatchQueue.main.async { [self] in
            guard generation == token else { return }
            session?.finishTasksAndInvalidate()
            session = nil
            isUpdating = false
            switch outcome {
            case .unchanged:
                CleanLinksPrefs.rulesCheckedAt = Date().timeIntervalSince1970
                CleanLinksPrefs.rulesError = ""
            case .updated(let rules, let hash):
                let now = Date().timeIntervalSince1970
                CleanLinksPrefs.rulesCheckedAt = now
                CleanLinksPrefs.rulesUpdatedAt = now
                CleanLinksPrefs.rulesHash = hash
                CleanLinksPrefs.rulesError = ""
                self.rules = rules
                source = .downloaded
            case .failed(let message):
                // Recorded only once it failed: an attempt cancelled by stop() leaves no trace.
                CleanLinksPrefs.rulesAttemptedAt = Date().timeIntervalSince1970
                CleanLinksPrefs.rulesError = message
            }
            onChange?()
        }
    }
}
