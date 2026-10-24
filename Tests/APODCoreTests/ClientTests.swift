import Foundation
import Testing
@testable import APODCore

struct ClientTests {
    static let page = """
    <meta property="og:title" content="APOD: 2026 October 1 - Test - NASA Science">
    <img class="x" src="https://assets.science.nasa.gov/dynamicimage/assets/apod/a.jpg?w=400">
    <h1 class="display-48 x">Test &amp; <i>picture</i></h1>
    <p class="media-detail-hero__description">Explanation: Seen by <a href="#">Webb</a> .
    Near <a>NGC 3132</a> , far away.</p>
    <th>Image Credit &amp; Copyright</th> <td><a>NASA</a> , <a>ESA</a></td>
    """

    @Test func pageEntryReadsTheWebsite() async throws {
        let http = FakeHTTP()
        http.route("https://science.nasa.gov/apod/?date=", json: Self.page)
        let client = APODClient(http: http, apiKey: "DEMO_KEY", patience: .quick)
        let entry = try await client.pageEntry("2026-10-01")
        #expect(entry.title == "Test & picture")
        #expect(entry.explanation == "Seen by Webb. Near NGC 3132, far away.")
        #expect(entry.copyright == "NASA, ESA")
        #expect(entry.hdurl == "https://assets.science.nasa.gov/content/dam/apod/a.jpg")
        #expect(entry.mediaType == "image")
        // Another day's page (or the landing page) is not this day's entry.
        await #expect(throws: APODError.self) { try await client.pageEntry("2026-10-02") }
    }

    @Test func onlyNasaHttpsImagesAreAccepted() {
        for (url, ok) in [("https://apod.nasa.gov/a.jpg", true),
                          ("https://assets.science.nasa.gov/a.jpg", true),
                          ("http://apod.nasa.gov/a.jpg", false),
                          ("https://nasa.gov.evil.example/a.jpg", false),
                          ("https://evil.example/nasa.gov/a.jpg", false)] {
            #expect(APODClient.acceptable(APODEntry(date: "2026-10-01", title: "t", mediaType: "image", url: url)) == ok, "\(url)")
        }
        #expect(APODClient.acceptable(APODEntry(date: "2026-10-01", title: "t", mediaType: "video", url: "https://youtube.com/x")))
        #expect(!APODClient.acceptable(APODEntry(date: "2026-10-01", title: "t", mediaType: "other")))
    }

    @Test func placeholderEntriesNeedThePage() {
        #expect(APODEntry(date: "2026-10-01").needsPage)
        #expect(APODEntry(date: "2026-10-01", title: "NASA Science").needsPage)
        #expect(APODEntry(date: "2026-10-01", title: "x", url: "https://science.nasa.gov/wp-content/themes/a/logo.png").needsPage)
        #expect(!APODEntry(date: "2026-10-01", title: "x", url: "https://apod.nasa.gov/a.jpg").needsPage)
    }

    @Test func malformedApiResponsesUseDateFallback() async throws {
        for body in ["not json", #"{"no":"date"}"#, #"[{"date":5}]"#, #"{"date":"2026-10-01","title":3}"#] {
            let http = FakeHTTP()
            http.route("https://api.nasa.gov/", json: body)
            let entries = try await APODClient(http: http, apiKey: "DEMO_KEY", patience: .quick)
                .entries([URLQueryItem(name: "date", value: "2026-10-01")], dates: ["2026-10-01"])
            #expect(entries == [APODEntry(date: "2026-10-01")], "\(body)")
        }
    }

    @Test func validVideoAndEmptyResultsDoNotTriggerFallback() async throws {
        for (body, count) in [(#"{"date":"2026-10-01","title":"v","media_type":"video","url":"https://youtube.com/x"}"#, 1),
                              ("[]", 0),
                              (#"[{"date":"2026-10-01","title":"o","media_type":"other"}]"#, 0)] {
            let http = FakeHTTP()
            http.route("https://api.nasa.gov/", json: body)
            let entries = try await APODClient(http: http, apiKey: "DEMO_KEY", patience: .quick)
                .entries([URLQueryItem(name: "date", value: "2026-10-01")], dates: ["2026-10-01"])
            #expect(entries.count == count, "\(body)")
            #expect(!http.asked.contains { $0.contains("science.nasa.gov") })
        }
    }

    @Test func rateLimitSaysWhy() async {
        let http = FakeHTTP()
        http.route("https://api.nasa.gov/", json: "{}", code: 429)
        let report = Reporter()
        _ = try? await APODClient(http: http, apiKey: "DEMO_KEY", patience: .quick, report: report)
            .entries([URLQueryItem(name: "date", value: "2026-10-01")], dates: ["2026-10-01"])
        // The website fallback dealt with it, but the reason was reported first.
        #expect(report.firstProblem == nil)
        let problems = Reporter()
        await #expect(throws: APODError.self) {
            try await APODClient(http: http, apiKey: "DEMO_KEY", patience: .quick, report: problems).api([])
        }
        #expect(problems.firstProblem?.hasPrefix("NASA API rate limit reached (shared DEMO_KEY)") == true)
    }

    @Test func personalKeys() {
        #expect(!APODClient.isPersonal("DEMO_KEY"))
        #expect(!APODClient.isPersonal(""))
        #expect(APODClient.isPersonal("abcdefghijklmnopqrstuvwxyz0123456789ABCD"))
    }

    @Test func apodDayChangesAtMidnightEastern() {
        // 03:00 UTC on 2 October is still 1 October in New York.
        let date = ISO8601DateFormatter().date(from: "2026-10-02T03:00:00Z")!
        #expect(APODDate.today(date) == "2026-10-01")
        #expect(APODDate.adding(-10, to: "2026-03-05") == "2026-02-23")
        #expect(APODDate.parse("2026-02-30") == nil)
    }
}
