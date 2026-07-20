import XCTest
@testable import SalesCentral

/// Pins `SDKMetadata.version` to the CHANGELOG's newest entry so a release
/// can't ship without bumping the constant. The admin's per-user "SDK"
/// field renders exactly this value — it kept reading "1.2.0" for every
/// 1.3.x build because the bump step in SDK_RELEASES.md was missed.
final class VersionTests: XCTestCase {

    func testSDKMetadataVersionMatchesChangelogHead() throws {
        let changelog = URL(fileURLWithPath: #filePath)     // …/Tests/SalesCentralTests/VersionTests.swift
            .deletingLastPathComponent()                    // …/Tests/SalesCentralTests
            .deletingLastPathComponent()                    // …/Tests
            .deletingLastPathComponent()                    // package root
            .appendingPathComponent("CHANGELOG.md")
        let text = try String(contentsOf: changelog, encoding: .utf8)
        let head = try XCTUnwrap(
            text.split(separator: "\n")
                .first { $0.hasPrefix("## [") }
                .flatMap { line -> String? in
                    guard let open = line.firstIndex(of: "["),
                          let close = line.firstIndex(of: "]"),
                          open < close else { return nil }
                    return String(line[line.index(after: open)..<close])
                },
            "CHANGELOG.md has no '## [x.y.z]' heading"
        )
        XCTAssertEqual(SDKMetadata.version, head,
                       "SDKMetadata.version must be bumped with every release — the admin shows this value on every user")
    }

    /// The constant actually rides the wire: `AppContext.current()` defaults
    /// its `sdkVersion` to it, and the server re-merges it on every
    /// `ensureUser`, so bumping the constant updates existing users on
    /// their next launch.
    func testAppContextCarriesSDKVersion() {
        XCTAssertEqual(AppContext.current().sdkVersion, SDKMetadata.version)
    }
}
