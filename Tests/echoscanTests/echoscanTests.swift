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
        XCTAssertEqual(sanitizeCaskVersion("3.6.2-57f0b637"), "3.6.2")
        XCTAssertEqual(sanitizeCaskVersion("1.5.0+20220101"), "1.5.0")
    }

    func testVersionParseStripsBuildMetadata() {
        XCTAssertEqual(Version.parse("3.6.2-57f0b637")?.segments, [3, 6, 2])
        XCTAssertEqual(Version.parse("1.5.0+20220101")?.segments, [1, 5, 0])
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

    func testCaskEntryDecodingWithLegacyTopLevelBundleID() throws {
        // Some older API snapshot formats still carry a top-level
        // bundle_id, but it is informational only and is no longer used for
        // matching; the .app artifact file names are the identity anchor.
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
        XCTAssertEqual(entry.appFileNames, ["GIMP.app"])
        XCTAssertEqual(entry.displayName, "GIMP")
        XCTAssertEqual(entry.version, "4.1.20,778")
    }

    func testCaskIndexLookupByAppFileName() throws {
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
        XCTAssertNotNil(index.lookup(appFileName: "GIMP"))
        XCTAssertNotNil(index.lookup(appFileName: "GIMP.app"))
        XCTAssertNil(index.lookup(appFileName: "An App With No Cask"))
    }

    func testCaskIndexPrefersAppFileArtifactOverNestedTarget() throws {
        // The artifacts entry writes "OpenCode.app" to /Applications, so both
        // the plain file reference and the target path must yield the same
        // "OpenCode.app" lookup key.
        let json = """
        [
          {
            "token": "opencode-desktop",
            "name": ["OpenCode"],
            "version": "2.0.32",
            "artifacts": [
              {"app": ["OpenCode.app"], "target": "/Applications/OpenCode.app"}
            ]
          }
        ]
        """
        let entries = try JSONDecoder().decode([CaskEntry].self, from: Data(json.utf8))
        let index = CaskIndex(casks: entries)
        let match = index.lookup(appFileName: "OpenCode")
        XCTAssertEqual(match?.token, "opencode-desktop")
    }

    func testCaskIndexRegistersAliases() throws {
        // Homebrew renames casks and keeps the old token as an alias; a local
        // app installed under the old token (e.g. "iina") must still resolve
        // to the renamed cask entry.
        let json = """
        [
          {
            "token": "some-cask",
            "name": ["Some Cask"],
            "version": "1.0",
            "aliases": ["old-token"],
            "artifacts": [
              ["app", ["Some Cask.app"]]
            ]
          },
          {
            "token": "renamed-cask",
            "name": ["Renamed"],
            "version": "2.0",
            "aliases": ["iina"],
            "artifacts": [
              {"app": ["IINA.app"], "target": "/Applications/IINA.app"}
            ]
          }
        ]
        """
        let entries = try JSONDecoder().decode([CaskEntry].self, from: Data(json.utf8))
        let index = CaskIndex(casks: entries)
        XCTAssertEqual(index.lookup(appFileName: "iina")?.token, "renamed-cask")
        XCTAssertEqual(index.lookup(appFileName: "old-token")?.token, "some-cask")
    }

    func testCaskIndexKeepsLookupWithoutBundleID() throws {
        // formulae.brew.sh API JSON no longer has a bundle_id field, so
        // decoding must not fail without one.
        let json = """
        [
          {
            "token": "qbittorrent",
            "name": ["qBittorrent"],
            "version": "5.2.3",
            "artifacts": [
              {"app": ["qBittorrent.app"], "target": "/Applications/qBittorrent.app"}
            ]
          }
        ]
        """
        let entries = try JSONDecoder().decode([CaskEntry].self, from: Data(json.utf8))
        let index = CaskIndex(casks: entries)
        XCTAssertEqual(index.lookup(appFileName: "qbittorrent")?.token, "qbittorrent")
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

    func testSparkleFeedParserSkipsItemsWithoutVersion() {
        let xml = """
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
          <channel>
            <item>
              <title>No release notes feed entry</title>
            </item>
            <item>
              <enclosure sparkle:shortVersionString="3.1.0" sparkle:version="310" />
            </item>
          </channel>
        </rss>
        """
        let parser = SparkleFeedParser(logger: Logger(verbose: false))
        let version = parser.parse(data: Data(xml.utf8))
        XCTAssertEqual(version, "3.1.0")
    }

    func testSparkleFeedParserSelectsHighestVersionRegardlessOfItemOrder() {
        let xml = """
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
          <channel>
            <item>
              <enclosure sparkle:shortVersionString="2.0.1" />
            </item>
            <item>
              <enclosure sparkle:shortVersionString="2.0.3" />
            </item>
            <item>
              <enclosure sparkle:shortVersionString="2.0.2" />
            </item>
          </channel>
        </rss>
        """
        let parser = SparkleFeedParser(logger: Logger(verbose: false))
        let version = parser.parse(data: Data(xml.utf8))
        XCTAssertEqual(version, "2.0.3")
    }

    func testSparkleFeedParserDoesNotCompareBuildNumberAgainstSemVer() {
        // Older items often only carry sparkle:version (a build number). Build
        // numbers must never be compared against semantic versions, otherwise
        // "1200" would beat "12.0".
        let xml = """
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
          <channel>
            <item>
              <enclosure sparkle:version="1200" />
            </item>
            <item>
              <enclosure sparkle:shortVersionString="12.0" />
            </item>
            <item>
              <enclosure sparkle:version="1201" />
            </item>
          </channel>
        </rss>
        """
        let parser = SparkleFeedParser(logger: Logger(verbose: false))
        let version = parser.parse(data: Data(xml.utf8))
        XCTAssertEqual(version, "12.0")
    }

    func testSparkleFeedParserFallsBackToHighestBuildNumber() {
        let xml = """
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
          <channel>
            <item>
              <enclosure sparkle:version="107" />
            </item>
            <item>
              <enclosure sparkle:version="201" />
            </item>
            <item>
              <enclosure sparkle:version="110" />
            </item>
          </channel>
        </rss>
        """
        let parser = SparkleFeedParser(logger: Logger(verbose: false))
        let version = parser.parse(data: Data(xml.utf8))
        XCTAssertEqual(version, "201")
    }

    func testSparkleFeedParserOverwritesFallbackWithParsableVersion() {
        let xml = """
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
          <channel>
            <item>
              <enclosure sparkle:shortVersionString="beta" />
            </item>
            <item>
              <title>Placeholder item</title>
            </item>
            <item>
              <enclosure sparkle:shortVersionString="2.0.3" />
            </item>
          </channel>
        </rss>
        """
        let parser = SparkleFeedParser(logger: Logger(verbose: false))
        let version = parser.parse(data: Data(xml.utf8))
        XCTAssertEqual(version, "2.0.3")
    }

    func testSparkleFeedParserReturnsUnparsableVersionAsFallback() {
        let xml = """
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
          <channel>
            <item>
              <enclosure sparkle:shortVersionString="latest" />
            </item>
            <item>
              <enclosure sparkle:shortVersionString="beta" />
            </item>
          </channel>
        </rss>
        """
        let parser = SparkleFeedParser(logger: Logger(verbose: false))
        let version = parser.parse(data: Data(xml.utf8))
        XCTAssertEqual(version, "latest")
    }

    func testSparkleFeedParserKeepsFirstWhenVersionsAreEqual() {
        let xml = """
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
          <channel>
            <item>
              <enclosure sparkle:shortVersionString="2.0.3" />
            </item>
            <item>
              <enclosure sparkle:shortVersionString="2.0.3" />
            </item>
          </channel>
        </rss>
        """
        let parser = SparkleFeedParser(logger: Logger(verbose: false))
        let version = parser.parse(data: Data(xml.utf8))
        XCTAssertEqual(version, "2.0.3")
    }

    func testSparkleFeedParserIgnoresFeedWithoutEnclosures() {
        let xml = """
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
          <channel>
            <item>
              <title>No release notes feed entry</title>
            </item>
          </channel>
        </rss>
        """
        let parser = SparkleFeedParser(logger: Logger(verbose: false))
        let version = parser.parse(data: Data(xml.utf8))
        XCTAssertNil(version)
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
    }
}
