import XCTest
@testable import echoscan

final class echoscanTests: XCTestCase {
    func testVersionParsing() {
        XCTAssertNil(Version.parse(nil))
        XCTAssertNil(Version.parse(""))
        XCTAssertNil(Version.parse("latest"))
        XCTAssertEqual(Version.parse("1.2.3")?.segments, [1, 2, 3])
        XCTAssertEqual(Version.parse("4.1.20,778")?.segments, [4, 1, 20])
        XCTAssertEqual(Version.parse("1.2b3")?.segments, [1, 2, 3])
    }

    func testVersionComparison() {
        let v1 = Version.parse("1.2.3")!
        let v2 = Version.parse("1.2.4")!
        let v3 = Version.parse("1.2.3.0")!
        XCTAssertTrue(v2 > v1)
        XCTAssertFalse(v1 > v2)
        XCTAssertFalse(v1 > v3)
        XCTAssertFalse(v3 > v1)
    }

    func testSanitizeCaskVersion() {
        XCTAssertEqual(sanitizeCaskVersion("4.1.20,778"), "4.1.20")
        XCTAssertEqual(sanitizeCaskVersion("2.0.1"), "2.0.1")
    }

    func testNormalizeAppName() {
        XCTAssertEqual(normalizeAppName("GIMP.app"), "gimp")
        XCTAssertEqual(normalizeAppName(" GIMP "), "gimp")
        XCTAssertEqual(normalizeAppName("My App.app"), "my app")
    }

    func testFNV1aHash() {
        XCTAssertEqual(fnv1a64Hex(""), "cbf29ce484222325")
        XCTAssertEqual(fnv1a64Hex("hello"), "a430d84680aabd0b")
    }

    func testJSONValueCollectAppNames() throws {
        let json = """
        [
          ["app", ["GIMP.app"]],
          {"binary": ["gimp"]},
          ["app", ["Second.app", {"target": "second"}]]
        ]
        """
        let data = Data(json.utf8)
        let values = try JSONDecoder().decode([JSONValue].self, from: data)
        var collected: [String] = []
        for value in values {
            value.collectAppNames(into: &collected)
        }
        XCTAssertTrue(collected.contains("GIMP.app"))
        XCTAssertTrue(collected.contains("Second.app"))
        XCTAssertFalse(collected.contains("gimp"))
    }

    func testCaskEntryDecoding() throws {
        let json = """
        {
          "token": "gimp",
          "name": ["GIMP"],
          "version": "4.1.20,778",
          "bundle_id": "org.gimp.gimp-2.10",
          "artifacts": [
            ["app", ["GIMP.app"]]
          ]
        }
        """
        let data = Data(json.utf8)
        let entry = try JSONDecoder().decode(CaskEntry.self, from: data)
        XCTAssertEqual(entry.token, "gimp")
        XCTAssertEqual(entry.bundleIDs, ["org.gimp.gimp-2.10"])
        XCTAssertTrue(entry.appNames.contains("GIMP.app"))
        XCTAssertEqual(entry.version, "4.1.20,778")
    }

    func testCaskIndexLookupByAppName() throws {
        let json = """
        [
          {
            "token": "gimp",
            "name": ["GIMP"],
            "version": "4.1.20,778",
            "artifacts": [
              ["app", ["GIMP.app"]]
            ]
          }
        ]
        """
        let data = Data(json.utf8)
        let entries = try JSONDecoder().decode([CaskEntry].self, from: data)
        let index = CaskIndex(casks: entries)
        let match = index.lookup(appName: "GIMP")
        XCTAssertNotNil(match)
        XCTAssertEqual(match?.token, "gimp")
    }

    func testSparkleFeedParser() {
        let xml = """
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
          <channel>
            <item>
              <enclosure sparkle:shortVersionString="2.0.1" sparkle:version="201" />
            </item>
          </channel>
        </rss>
        """
        let parser = SparkleFeedParser(logger: Logger(verbose: false))
        let version = parser.parse(data: Data(xml.utf8))
        XCTAssertEqual(version, "2.0.1")
    }

    func testSortedResultsByStatusThenModDate() {
        let now = Date()
        let older = now.addingTimeInterval(-3600)
        let newest = now.addingTimeInterval(3600)

        let results = [
            ScanResult(appName: "B", localVersion: "1", remoteVersion: "2", source: "Homebrew", status: .unknown, modDate: now),
            ScanResult(appName: "A", localVersion: "1", remoteVersion: "2", source: "Homebrew", status: .update, modDate: older),
            ScanResult(appName: "C", localVersion: "1", remoteVersion: "2", source: "Homebrew", status: .update, modDate: newest),
            ScanResult(appName: "D", localVersion: "1", remoteVersion: "2", source: "Homebrew", status: .current, modDate: newest)
        ]

        let sorted = OutputRenderer.sortedResults(results)
        XCTAssertEqual(sorted.map { $0.appName }, ["C", "A", "B"])
    }

    func testCacheDirectoriesStayInHomeDotDir() throws {
        let cache = try CacheStore.makeDefault()
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertTrue(cache.directory.path.hasPrefix(home))
        XCTAssertTrue(cache.directory.path.hasSuffix("/.echoscan"))
        XCTAssertFalse(cache.directory.path.contains("/Library/Caches/"))
    }

    func testDerivedCachePaths() throws {
        let base = URL(fileURLWithPath: "/tmp/echoscan-test-\(UUID().uuidString)", isDirectory: true)
        let sparkle = try SparkleCacheStore.makeDefault(baseDirectory: base)
        XCTAssertEqual(sparkle.directory.path, base.appendingPathComponent("sparkle", isDirectory: true).path)
        let urlCachePath = URLCacheConfigurator.diskPath(baseDirectory: base)
        XCTAssertEqual(urlCachePath, base.appendingPathComponent("urlcache", isDirectory: true).path)
        XCTAssertFalse(urlCachePath.contains("/Library/Caches/"))
    }
}
