import Foundation
import Darwin

@main
struct EchoScan {
    static func main() {
        let options = CLIOptions.parse()
        let logger = Logger(verbose: options.verbose)

        if options.showHelp {
            HelpPrinter.print()
            return
        }

        do {
            logger.event("EchoScan starting")
            let cache = try CacheStore.makeDefault()
            logger.event("Cache directory: \(cache.directory.path)")
            let client = CaskAPIClient(cache: cache, logger: logger)
            let casks = try client.fetchCasks()
            let index = CaskIndex(casks: casks)

            let apps = try LocalAppFinder.findApps(logger: logger)
            logger.event("Scanning \(apps.count) local app(s)")
            let scanner = Scanner(index: index, logger: logger)
            let results = try scanner.scan(apps: apps)

            OutputRenderer.render(results: results, useColor: options.useColor)
            logger.event("EchoScan finished")
        } catch {
            logger.error("fatal: \(error)")
            exit(1)
        }
    }
}

// MARK: - CLI

struct CLIOptions {
    let useColor: Bool
    let showHelp: Bool
    let verbose: Bool

    static func parse() -> CLIOptions {
        var useColor = true
        var showHelp = false
        var verbose = false

        for arg in CommandLine.arguments.dropFirst() {
            switch arg {
            case "--no-color":
                useColor = false
            case "-h", "--help":
                showHelp = true
            case "-v", "--verbose":
                verbose = true
            default:
                break
            }
        }

        let isTTY = isatty(fileno(stdout)) != 0
        if !isTTY { useColor = false }

        return CLIOptions(useColor: useColor, showHelp: showHelp, verbose: verbose)
    }
}

enum HelpPrinter {
    static func print() {
        let text = """
        EchoScan scans local .app bundles and compares versions against Homebrew Cask.

        Usage:
          echoscan [--no-color] [--verbose]

        Options:
          --no-color   Disable ANSI colors
          --verbose    Print extra diagnostics to stderr
          -h, --help   Show help
        """
        Swift.print(text)
    }
}

// MARK: - Logging

struct Logger {
    let verbose: Bool

    func info(_ message: String) {
        guard verbose else { return }
        write(message)
    }

    func error(_ message: String) {
        write(message)
    }

    func event(_ message: String) {
        write("\(Logger.timestamp()) \(message)")
    }

    func scan(_ message: String) {
        write(message)
    }

    private func write(_ message: String) {
        if let data = (message + "\n").data(using: .utf8) {
            FileHandle.standardError.write(data)
        }
    }

    static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date())
    }
}

// MARK: - Cache

struct CacheStore {
    let directory: URL
    let dataURL: URL
    let metaURL: URL

    static func makeDefault() throws -> CacheStore {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent(".echoscan", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return CacheStore(directory: dir,
                          dataURL: dir.appendingPathComponent("cask.json"),
                          metaURL: dir.appendingPathComponent("cask.meta.json"))
    }

    func loadMetadata() -> CacheMetadata? {
        guard let data = try? Data(contentsOf: metaURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(CacheMetadata.self, from: data)
    }

    func saveMetadata(_ meta: CacheMetadata) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(meta)
        try data.write(to: metaURL, options: [.atomic])
    }

    func loadData() -> Data? {
        return try? Data(contentsOf: dataURL)
    }

    func saveData(_ data: Data) throws {
        try data.write(to: dataURL, options: [.atomic])
    }
}

struct CacheMetadata: Codable {
    let etag: String?
    let lastModified: String?
    let savedAt: Date
}

// MARK: - Cask API

struct CaskAPIClient {
    private let cache: CacheStore
    private let logger: Logger
    private let endpoint = URL(string: "https://formulae.brew.sh/api/cask.json")!

    init(cache: CacheStore, logger: Logger) {
        self.cache = cache
        self.logger = logger
    }

    func fetchCasks() throws -> [CaskEntry] {
        logger.event("Fetching Homebrew cask index")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("echoscan", forHTTPHeaderField: "User-Agent")

        let cachedMeta = cache.loadMetadata()
        if let etag = cachedMeta?.etag {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        if let lastModified = cachedMeta?.lastModified {
            request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since")
        }

        let (data, response) = try URLSession.shared.syncData(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ScanError.network("Invalid response")
        }

        switch http.statusCode {
        case 200:
            let etag = headerValue(from: http, name: "ETag")
            let lastModified = headerValue(from: http, name: "Last-Modified")
            try cache.saveData(data)
            try cache.saveMetadata(CacheMetadata(etag: etag, lastModified: lastModified, savedAt: Date()))
            logger.event("Cask index updated (HTTP 200)")
            let casks = try decodeCasks(from: data)
            logger.event("Loaded \(casks.count) casks")
            return casks
        case 304:
            logger.event("Cask index not modified (HTTP 304), using cache")
            if let cached = cache.loadData() {
                let casks = try decodeCasks(from: cached)
                logger.event("Loaded \(casks.count) casks")
                return casks
            }
            logger.event("Cache miss after 304; refetching")
            return try fetchWithoutCache()
        default:
            logger.event("Unexpected status \(http.statusCode). Using cached data if present.")
            if let cached = cache.loadData() {
                let casks = try decodeCasks(from: cached)
                logger.event("Loaded \(casks.count) casks")
                return casks
            }
            throw ScanError.network("HTTP \(http.statusCode)")
        }
    }

    private func fetchWithoutCache() throws -> [CaskEntry] {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("echoscan", forHTTPHeaderField: "User-Agent")
        let (data, response) = try URLSession.shared.syncData(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw ScanError.network("Failed to refresh")
        }
        let etag = headerValue(from: http, name: "ETag")
        let lastModified = headerValue(from: http, name: "Last-Modified")
        try cache.saveData(data)
        try cache.saveMetadata(CacheMetadata(etag: etag, lastModified: lastModified, savedAt: Date()))
        logger.event("Cask index refreshed")
        let casks = try decodeCasks(from: data)
        logger.event("Loaded \(casks.count) casks")
        return casks
    }

    private func headerValue(from response: HTTPURLResponse, name: String) -> String? {
        for (key, value) in response.allHeaderFields {
            guard let key = key as? String else { continue }
            if key.caseInsensitiveCompare(name) == .orderedSame {
                return value as? String
            }
        }
        return nil
    }

    private func decodeCasks(from data: Data) throws -> [CaskEntry] {
        let decoder = JSONDecoder()
        return try decoder.decode([CaskEntry].self, from: data)
    }
}

// MARK: - Models

struct CaskEntry: Decodable {
    let token: String
    let name: [String]?
    let desc: String?
    let homepage: String?
    let version: String
    let bundleIDs: [String]
    let appNames: [String]

    enum CodingKeys: String, CodingKey {
        case token
        case name
        case desc
        case homepage
        case version
        case bundleID = "bundle_id"
        case artifacts
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        token = try container.decode(String.self, forKey: .token)
        if let one = try? container.decode(String.self, forKey: .name) {
            name = [one]
        } else if let many = try? container.decode([String].self, forKey: .name) {
            name = many
        } else {
            name = nil
        }
        desc = try container.decodeIfPresent(String.self, forKey: .desc)
        homepage = try container.decodeIfPresent(String.self, forKey: .homepage)
        version = (try? container.decode(String.self, forKey: .version)) ?? ""

        if let one = try? container.decode(String.self, forKey: .bundleID) {
            bundleIDs = [one]
        } else if let many = try? container.decode([String].self, forKey: .bundleID) {
            bundleIDs = many
        } else {
            bundleIDs = []
        }

        let artifacts = (try? container.decode([JSONValue].self, forKey: .artifacts)) ?? []
        var collected: [String] = []
        for value in artifacts {
            value.collectAppNames(into: &collected)
        }
        appNames = Array(Set(collected))
    }

    var displayName: String {
        if let name = name?.first, !name.isEmpty { return name }
        return token
    }
}

struct CaskIndex {
    private var bundleMap: [String: CaskEntry] = [:]
    private var appNameMap: [String: CaskEntry] = [:]

    init(casks: [CaskEntry]) {
        for cask in casks {
            for id in cask.bundleIDs {
                if bundleMap[id] == nil {
                    bundleMap[id] = cask
                }
            }
            for appName in cask.appNames {
                let key = normalizeAppName(appName)
                if !key.isEmpty, appNameMap[key] == nil {
                    appNameMap[key] = cask
                }
            }
        }
    }

    func lookup(bundleID: String) -> CaskEntry? {
        return bundleMap[bundleID]
    }

    func lookup(appName: String) -> CaskEntry? {
        return appNameMap[normalizeAppName(appName)]
    }
}

struct LocalApp {
    let url: URL
    let name: String
    let bundleID: String?
    let version: String?
    let sparkleFeed: URL?
}

// MARK: - Local Discovery

enum LocalAppFinder {
    static func findApps(logger: Logger) throws -> [LocalApp] {
        let query = "kMDItemContentType == 'com.apple.application-bundle'"
        logger.event("Searching /Applications via mdfind")
        let output = try ProcessRunner.run("/usr/bin/mdfind", ["-onlyin", "/Applications", query])
        let paths = output.split(separator: "\n").map { String($0) }
        var apps: [LocalApp] = []
        var skippedNested = 0
        var skippedAppStore = 0
        var skippedApple = 0
        var skippedNoBundle = 0

        for path in paths {
            guard path.hasSuffix(".app") else { continue }
            let url = URL(fileURLWithPath: path)
            guard url.path.hasPrefix("/Applications/") else { continue }
            guard !isNestedApp(url: url) else { skippedNested += 1; continue }
            guard !isAppStoreApp(url: url) else { skippedAppStore += 1; continue }
            guard let app = readBundle(at: url, logger: logger) else { skippedNoBundle += 1; continue }
            if let bundleID = app.bundleID, bundleID.hasPrefix("com.apple.") { skippedApple += 1; continue }
            apps.append(app)
        }

        logger.event("Found \(apps.count) app(s) after filtering (\(paths.count) candidates, \(skippedNested) nested, \(skippedAppStore) App Store, \(skippedApple) Apple, \(skippedNoBundle) missing bundle)")
        return apps.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    private static func isNestedApp(url: URL) -> Bool {
        let components = url.pathComponents
        guard components.count > 1 else { return false }
        for component in components.dropLast() {
            if component.hasSuffix(".app") { return true }
        }
        return false
    }

    private static func isAppStoreApp(url: URL) -> Bool {
        let fm = FileManager.default
        if let bundle = Bundle(url: url),
           let receiptURL = bundle.appStoreReceiptURL,
           fm.fileExists(atPath: receiptURL.path) {
            return true
        }

        let candidates = [
            url.appendingPathComponent("Contents/_MASReceipt/receipt"),
            url.appendingPathComponent("_MASReceipt/receipt"),
            url.appendingPathComponent("Contents/_MASReceipt"),
            url.appendingPathComponent("_MASReceipt"),
            url.appendingPathComponent("iTunesMetadata.plist"),
            url.appendingPathComponent("Contents/iTunesMetadata.plist"),
            url.appendingPathComponent("Wrapper/iTunesMetadata.plist")
        ]

        for candidate in candidates where fm.fileExists(atPath: candidate.path) {
            return true
        }
        return false
    }

    private static func readBundle(at url: URL, logger: Logger) -> LocalApp? {
        guard let bundle = Bundle(url: url) else { return nil }
        let info = bundle.infoDictionary ?? [:]

        let name = (info["CFBundleDisplayName"] as? String)
            ?? (info["CFBundleName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent

        let bundleID = bundle.bundleIdentifier
        let version = (info["CFBundleShortVersionString"] as? String)
            ?? (info["CFBundleVersion"] as? String)

        let sparkleFeed = (info["SUFeedURL"] as? String).flatMap { URL(string: $0) }
        if bundleID == nil {
            logger.info("Missing bundle ID for \(name)")
        }

        return LocalApp(url: url, name: name, bundleID: bundleID, version: version, sparkleFeed: sparkleFeed)
    }
}

// MARK: - Versioning

struct Version: Comparable {
    let segments: [Int]
    let raw: String

    static func parse(_ string: String?) -> Version? {
        guard var value = string?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        if value.lowercased() == "latest" { return nil }
        if let comma = value.firstIndex(of: ",") {
            value = String(value[..<comma])
        }
        let numbers = value.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        if numbers.isEmpty { return nil }
        return Version(segments: numbers, raw: value)
    }

    static func < (lhs: Version, rhs: Version) -> Bool {
        let count = max(lhs.segments.count, rhs.segments.count)
        for idx in 0..<count {
            let left = idx < lhs.segments.count ? lhs.segments[idx] : 0
            let right = idx < rhs.segments.count ? rhs.segments[idx] : 0
            if left != right { return left < right }
        }
        return false
    }
}

// MARK: - Sparkle

struct SparkleClient {
    let logger: Logger

    func fetchLatestVersion(feedURL: URL) -> String? {
        var request = URLRequest(url: feedURL)
        request.httpMethod = "GET"
        request.setValue("echoscan", forHTTPHeaderField: "User-Agent")

        do {
            let (data, _) = try URLSession.shared.syncData(for: request)
            let parser = SparkleFeedParser(logger: logger)
            return parser.parse(data: data)
        } catch {
            logger.info("Sparkle fetch failed for \(feedURL.absoluteString): \(error)")
            return nil
        }
    }
}

final class SparkleFeedParser: NSObject, XMLParserDelegate {
    private let logger: Logger
    private var latestVersion: String?
    private var insideItem = false

    init(logger: Logger) {
        self.logger = logger
    }

    func parse(data: Data) -> String? {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return latestVersion
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        if elementName.lowercased() == "item" {
            insideItem = true
        }

        guard insideItem else { return }
        if elementName.lowercased() == "enclosure" {
            if latestVersion == nil {
                if let version = attributeDict["sparkle:shortVersionString"] ?? attributeDict["shortVersionString"] {
                    latestVersion = version
                } else if let version = attributeDict["sparkle:version"] ?? attributeDict["version"] {
                    latestVersion = version
                }
            }
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName.lowercased() == "item" {
            insideItem = false
        }
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        logger.info("Sparkle XML parse error: \(parseError)")
    }
}

// MARK: - Scanner

struct ScanResult {
    let appName: String
    let localVersion: String
    let remoteVersion: String
    let source: String
    let status: Status
}

enum Status: String {
    case update = "Update"
    case current = "Current"
    case unknown = "Check"
    case headsup = "Possible"
}

struct Scanner {
    let index: CaskIndex
    let logger: Logger
    var sparkle: SparkleClient { SparkleClient(logger: logger) }

    func scan(apps: [LocalApp]) throws -> [ScanResult] {
        var results: [ScanResult] = []

        for app in apps {
            let localVersion = app.version ?? "N/A"

            if let bundleID = app.bundleID, let cask = index.lookup(bundleID: bundleID) {
                let remoteVersion = sanitizeCaskVersion(cask.version)
                let status = compare(local: app.version, remote: remoteVersion)
                logger.scan("\(Logger.timestamp()) Scanning \(app.name), current version \(localVersion), remote found in cask")
                results.append(ScanResult(appName: app.name,
                                          localVersion: localVersion,
                                          remoteVersion: remoteVersion.isEmpty ? "N/A" : remoteVersion,
                                          source: "Homebrew",
                                          status: status))
                continue
            }

            if let cask = index.lookup(appName: app.name) {
                let remoteVersion = sanitizeCaskVersion(cask.version)
                let status = compare(local: app.version, remote: remoteVersion, weakMatch: true)
                logger.scan("\(Logger.timestamp()) Scanning \(app.name), current version \(localVersion), remote found in cask")
                results.append(ScanResult(appName: app.name,
                                          localVersion: localVersion,
                                          remoteVersion: remoteVersion.isEmpty ? "N/A" : remoteVersion,
                                          source: "Homebrew",
                                          status: status))
                continue
            }

            let fileName = app.url.deletingPathExtension().lastPathComponent
            if fileName != app.name, let cask = index.lookup(appName: fileName) {
                let remoteVersion = sanitizeCaskVersion(cask.version)
                let status = compare(local: app.version, remote: remoteVersion, weakMatch: true)
                logger.scan("\(Logger.timestamp()) Scanning \(app.name), current version \(localVersion), remote found in cask")
                results.append(ScanResult(appName: app.name,
                                          localVersion: localVersion,
                                          remoteVersion: remoteVersion.isEmpty ? "N/A" : remoteVersion,
                                          source: "Homebrew",
                                          status: status))
                continue
            }

            if let feed = app.sparkleFeed, let remote = sparkle.fetchLatestVersion(feedURL: feed) {
                let status = compare(local: app.version, remote: remote)
                logger.scan("\(Logger.timestamp()) Scanning \(app.name), current version \(localVersion), remote found in sparkle")
                results.append(ScanResult(appName: app.name,
                                          localVersion: localVersion,
                                          remoteVersion: remote,
                                          source: "Sparkle",
                                          status: status))
                continue
            }

            results.append(ScanResult(appName: app.name,
                                      localVersion: localVersion,
                                      remoteVersion: "N/A",
                                      source: "Manual",
                                      status: .unknown))
        }

        return results
    }

    private func compare(local: String?, remote: String) -> Status {
        return compare(local: local, remote: remote, weakMatch: false)
    }

    private func compare(local: String?, remote: String, weakMatch: Bool) -> Status {
        guard let localVersion = Version.parse(local), let remoteVersion = Version.parse(remote) else {
            return .unknown
        }
        if remoteVersion > localVersion {
            return weakMatch ? .headsup : .update
        }
        return .current
    }
}

// MARK: - Output

enum OutputRenderer {
    static func render(results: [ScanResult], useColor: Bool) {
        let filtered = results.filter { $0.status != .current }
        let sorted = filtered.sorted {
            let lhsRank = statusRank($0.status)
            let rhsRank = statusRank($1.status)
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            return $0.appName.lowercased() < $1.appName.lowercased()
        }

        let rows = sorted.map { result -> [String] in
            let statusText = colorize(result.status.rawValue, status: result.status, useColor: useColor)
            return [result.appName, result.localVersion, result.remoteVersion, result.source, statusText]
        }

        let headers = ["App", "Local", "Remote", "Source", "Status"]
        TablePrinter.print(headers: headers, rows: rows)

        let updates = sorted.filter { $0.status == .update }.count
        let headsups = sorted.filter { $0.status == .headsup }.count
        let checks = sorted.filter { $0.status == .unknown }.count
        let total = sorted.count
        Swift.print("\n\(updates) update(s) available, \(headsups) possible update(s), \(checks) check(s) required, \(total) shown.")
    }

    private static func colorize(_ text: String, status: Status, useColor: Bool) -> String {
        guard useColor else { return text }
        switch status {
        case .update:
            return "\u{001B}[31m\(text)\u{001B}[0m"
        case .current:
            return "\u{001B}[32m\(text)\u{001B}[0m"
        case .unknown:
            return "\u{001B}[33m\(text)\u{001B}[0m"
        case .headsup:
            return "\u{001B}[36m\(text)\u{001B}[0m"
        }
    }

    private static func statusRank(_ status: Status) -> Int {
        switch status {
        case .update:
            return 0
        case .headsup:
            return 1
        case .unknown:
            return 2
        case .current:
            return 3
        }
    }
}

struct TablePrinter {
    static func print(headers: [String], rows: [[String]]) {
        guard !headers.isEmpty else { return }
        var widths = headers.map { $0.count }

        for row in rows {
            for (idx, cell) in row.enumerated() where idx < widths.count {
                widths[idx] = max(widths[idx], cell.stripANSI().count)
            }
        }

        let headerLine = zip(headers, widths).map { pad($0, to: $1) }.joined(separator: "  ")
        Swift.print(headerLine)
        let separator = widths.map { String(repeating: "-", count: $0) }.joined(separator: "  ")
        Swift.print(separator)

        for row in rows {
            let line = zip(row, widths).map { pad($0, to: $1) }.joined(separator: "  ")
            Swift.print(line)
        }
    }

    private static func pad(_ text: String, to width: Int) -> String {
        let visible = text.stripANSI().count
        let padding = max(0, width - visible)
        return text + String(repeating: " ", count: padding)
    }
}

// MARK: - Helpers

struct ProcessRunner {
    static func run(_ launchPath: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            throw ScanError.network("Process failed: \(launchPath)")
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return "" }
        return output
    }
}

enum ScanError: Error, CustomStringConvertible {
    case network(String)

    var description: String {
        switch self {
        case .network(let message):
            return message
        }
    }
}

extension URLSession {
    func syncData(for request: URLRequest) throws -> (Data, URLResponse) {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox<Result<(Data, URLResponse), Error>>()

        let task = dataTask(with: request) { data, response, error in
            if let error = error {
                box.value = .failure(error)
            } else if let data = data, let response = response {
                box.value = .success((data, response))
            } else {
                box.value = .failure(ScanError.network("Empty response"))
            }
            semaphore.signal()
        }
        task.resume()
        semaphore.wait()

        guard let result = box.value else {
            throw ScanError.network("No response")
        }

        switch result {
        case .success(let value):
            return value
        case .failure(let error):
            throw error
        }
    }
}

final class ResultBox<T>: @unchecked Sendable {
    var value: T?
}

extension String {
    func stripANSI() -> String {
        let pattern = "\\u001B\\[[0-9;]*m"
        return self.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
    }
}

func normalizeAppName(_ name: String) -> String {
    var value = name.trimmingCharacters(in: .whitespacesAndNewlines)
    if value.lowercased().hasSuffix(".app") {
        value = String(value.dropLast(4))
    }
    return value.lowercased()
}

func sanitizeCaskVersion(_ version: String) -> String {
    if let comma = version.firstIndex(of: ",") {
        return String(version[..<comma])
    }
    return version
}

enum JSONValue: Decodable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .null
        }
    }

    func collectAppNames(into output: inout [String]) {
        switch self {
        case .string(let value):
            if value.lowercased().hasSuffix(".app") {
                output.append(value)
            }
        case .array(let values):
            for value in values {
                value.collectAppNames(into: &output)
            }
        case .object(let dict):
            for value in dict.values {
                value.collectAppNames(into: &output)
            }
        case .number, .bool, .null:
            break
        }
    }
}
