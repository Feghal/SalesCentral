import XCTest
@testable import SalesCentral

/// AdServices is the only Apple API that attributes an install to a campaign
/// for an individual user, so what it maps to is what the backend's revenue
/// breakdowns are built on. These cover the mapping and the retry contract; the
/// token read itself is a system call with no seam worth faking.
final class AdServicesAttributionTests: XCTestCase {

    private typealias Subject = AdServicesAttribution

    // MARK: - Mapping

    func testAttributedInstallMapsEveryField() {
        let response = Subject.Response(
            attribution: true, orgId: 40669820, campaignId: 542370539,
            conversionType: "Download", adGroupId: 542370540,
            countryOrRegion: "US", keywordId: 87675432, adId: 542370543
        )
        let m = Subject.marketingContext(from: response)
        XCTAssertEqual(m?.attributionSource, "asa")
        XCTAssertEqual(m?.campaign, "542370539")
        XCTAssertEqual(m?.utmSource, "apple_search_ads")
        XCTAssertEqual(m?.utmMedium, "Download")
        XCTAssertEqual(m?.utmCampaign, "542370539")
        XCTAssertEqual(m?.utmTerm, "87675432")
        XCTAssertEqual(m?.utmContent, "542370543", "adId is narrower than adGroupId and wins")
    }

    /// The single most important case here. `attribution: false` means "not
    /// Apple Search Ads" — it does NOT mean organic, because the install may
    /// have come from Google or Meta. Recording organic would misfile every
    /// paid non-Apple install, and acquisition fields are write-once on the
    /// server, so it could never be corrected afterwards.
    func testUnattributedInstallRecordsNothingAndNeverClaimsOrganic() {
        let m = Subject.marketingContext(from: Subject.Response(attribution: false))
        XCTAssertNil(m, "a non-Search-Ads install must contribute no marketing fields at all")
    }

    func testAdGroupIsTheFallbackCreativeIdentifier() {
        let response = Subject.Response(
            attribution: true, campaignId: 1, adGroupId: 99, adId: nil
        )
        XCTAssertEqual(Subject.marketingContext(from: response)?.utmContent, "99")
    }

    /// Campaign types without keywords (Search Tab, Display) omit these, and a
    /// forced unwrap or a literal "nil" string would poison the breakdown.
    func testAbsentOptionalIdsStayAbsent() {
        let response = Subject.Response(attribution: true, campaignId: 7)
        let m = Subject.marketingContext(from: response)
        XCTAssertEqual(m?.campaign, "7")
        XCTAssertNil(m?.utmTerm)
        XCTAssertNil(m?.utmContent)
        XCTAssertNil(m?.utmMedium)
    }

    // MARK: - Decoding

    func testDecodesApplesPayloadShape() throws {
        let json = Data("""
        {"attribution":true,"orgId":40669820,"campaignId":542370539,
         "conversionType":"Download","adGroupId":542370540,
         "countryOrRegion":"US","keywordId":87675432,"adId":542370543}
        """.utf8)
        let r = try JSONDecoder().decode(Subject.Response.self, from: json)
        XCTAssertTrue(r.attribution)
        XCTAssertEqual(r.campaignId, 542370539)
    }

    /// Apple sends the bare `{"attribution": false}` for an unattributed
    /// install — every other key absent. A decoder requiring them would throw
    /// and the outcome would be misread as "unavailable", retried forever.
    func testDecodesBareUnattributedPayload() throws {
        let r = try JSONDecoder().decode(Subject.Response.self, from: Data(#"{"attribution":false}"#.utf8))
        XCTAssertFalse(r.attribution)
        XCTAssertNil(r.campaignId)
    }

    // MARK: - Exchange + retry

    func testExchangeParsesA200() async throws {
        AdServicesStubURLProtocol.responses = [(200, Data(#"{"attribution":true,"campaignId":5}"#.utf8))]
        let r = try await Subject.exchange(token: "tok", session: AdServicesStubURLProtocol.session())
        XCTAssertEqual(r.campaignId, 5)
        XCTAssertEqual(AdServicesStubURLProtocol.requestCount, 1)
    }

    /// 404 is the EXPECTED state in the seconds after an install, not a
    /// verdict. Treating it as "no attribution" is how a Search Ads install
    /// gets permanently misfiled.
    func testFourOhFourIsRetriedThenGivesUpAsUnavailable() async {
        AdServicesStubURLProtocol.responses = [(404, Data()), (404, Data()), (404, Data())]
        // Zero delay: this asserts the retry CONTRACT, not the wall clock.
        let outcome = await Subject.resolve(token: "tok",
                                            session: AdServicesStubURLProtocol.session(),
                                            retryDelay: .zero)
        XCTAssertEqual(outcome, .unavailable, "unavailable is retryable; notAppleSearchAds is not")
        XCTAssertNotEqual(outcome, .notAppleSearchAds)
        XCTAssertEqual(AdServicesStubURLProtocol.requestCount, Subject.maxAttempts,
                       "a 404 right after install must be retried, not taken as a verdict")
    }

    /// A definitive "not Search Ads" must NOT be retried — it is an answer.
    func testUnattributedAnswerIsNotRetried() async {
        AdServicesStubURLProtocol.responses = [(200, Data(#"{"attribution":false}"#.utf8))]
        let outcome = await Subject.resolve(token: "tok",
                                            session: AdServicesStubURLProtocol.session(),
                                            retryDelay: .zero)
        XCTAssertEqual(outcome, .notAppleSearchAds)
        XCTAssertEqual(AdServicesStubURLProtocol.requestCount, 1)
    }

    /// No token is the normal state on the simulator, on watchOS, and in any
    /// build that did not come from the App Store. It must read as retryable,
    /// never as "this install was not from Search Ads".
    func testMissingTokenIsUnavailableNotAVerdict() async {
        let outcome = await Subject.resolve(token: nil,
                                            session: AdServicesStubURLProtocol.session(),
                                            retryDelay: .zero)
        XCTAssertEqual(outcome, .unavailable)
        XCTAssertEqual(AdServicesStubURLProtocol.requestCount, 0, "no token, no call to Apple")
    }

    func testExchangeSendsTheTokenAsPlainTextBody() async throws {
        AdServicesStubURLProtocol.responses = [(200, Data(#"{"attribution":false}"#.utf8))]
        _ = try await Subject.exchange(token: "my-token", session: AdServicesStubURLProtocol.session())
        XCTAssertEqual(AdServicesStubURLProtocol.lastContentType, "text/plain")
        XCTAssertEqual(AdServicesStubURLProtocol.lastBody.flatMap { String(data: $0, encoding: .utf8) }, "my-token")
        XCTAssertEqual(AdServicesStubURLProtocol.lastURL?.host, "api-adservices.apple.com")
    }

    override func setUp() {
        super.setUp()
        AdServicesStubURLProtocol.reset()
    }
}

/// Minimal URLProtocol stub — returns queued responses in order and records
/// what the SDK actually put on the wire.
final class AdServicesStubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var responses: [(Int, Data)] = []
    nonisolated(unsafe) static var requestCount = 0
    nonisolated(unsafe) static var lastBody: Data?
    nonisolated(unsafe) static var lastContentType: String?
    nonisolated(unsafe) static var lastURL: URL?

    static func reset() {
        responses = []; requestCount = 0
        lastBody = nil; lastContentType = nil; lastURL = nil
    }

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AdServicesStubURLProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requestCount += 1
        Self.lastURL = request.url
        Self.lastContentType = request.value(forHTTPHeaderField: "Content-Type")
        // URLProtocol strips httpBody into httpBodyStream; read whichever is set.
        Self.lastBody = request.httpBody ?? request.httpBodyStream.map { stream in
            stream.open(); defer { stream.close() }
            var data = Data(); var buf = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let n = stream.read(&buf, maxLength: buf.count)
                if n <= 0 { break }
                data.append(contentsOf: buf[0..<n])
            }
            return data
        }

        let (status, body) = Self.responses.isEmpty
            ? (500, Data())
            : Self.responses.removeFirst()
        let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                       httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
