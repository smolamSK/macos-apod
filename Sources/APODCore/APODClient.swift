// Talking to NASA: the APOD API, and science.nasa.gov's pages when the API lets us down.
import Foundation

public struct APODEntry: Codable, Equatable, Sendable {
    public var date: String
    public var title: String?
    public var explanation: String?
    public var copyright: String?
    public var mediaType: String?
    public var url: String?
    public var hdurl: String?

    enum CodingKeys: String, CodingKey {
        case date, title, explanation, copyright, url, hdurl
        case mediaType = "media_type"
    }

    public init(date: String, title: String? = nil, explanation: String? = nil, copyright: String? = nil,
                mediaType: String? = nil, url: String? = nil, hdurl: String? = nil) {
        self.date = date
        self.title = title
        self.explanation = explanation
        self.copyright = copyright
        self.mediaType = mediaType
        self.url = url
        self.hdurl = hdurl
    }

    /// Since APOD moved to science.nasa.gov the API can return the site's logo and name
    /// instead of the real entry; such entries, and bare {"date": ...} stubs, need pageEntry.
    public var needsPage: Bool {
        title == nil || title == "NASA Science" || (url ?? "").contains("/wp-content/themes/")
    }

    public var isVideo: Bool { mediaType == "video" }
    public var bestURL: String? { hdurl ?? url }
    public var page: String { "https://science.nasa.gov/apod/?date=\(date)" }

    /// The credit on one line.
    public var credit: String {
        (copyright ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

public enum APODError: Error, LocalizedError, Equatable {
    case message(String)
    public var errorDescription: String? {
        switch self {
        case .message(let m): m
        }
    }
}

/// Retry policy: patient in the background, quick when someone clicked a button.
public struct Patience: Sendable {
    public var retries: Int
    public var delay: TimeInterval
    public var maxTime: TimeInterval
    public var requestTimeout: TimeInterval
    public var downloadTimeout: TimeInterval

    public static let background = Patience(retries: 10, delay: 30, maxTime: 900, requestTimeout: 60, downloadTimeout: 300)
    public static let quick = Patience(retries: 2, delay: 3, maxTime: 20, requestTimeout: 15, downloadTimeout: 240)
}

/// The network as the client needs it, so that tests can stand in for NASA.
public protocol HTTP: Sendable {
    /// GET url; the body and status code, whatever the status.
    func get(_ url: URL, timeout: TimeInterval) async throws -> (Data, Int)
    /// At most `bytes` bytes from the start of url, asking for a range.
    func head(_ url: URL, bytes: Int, timeout: TimeInterval) async throws -> Data
    /// Download url to file, https only, calling progress(done, total) as it goes.
    func download(_ url: URL, to file: URL, timeout: TimeInterval,
                  progress: @escaping @Sendable (Int64, Int64) -> Void) async throws
}

public struct APODClient: Sendable {
    public var http: HTTP
    public var apiKey: String
    public var patience: Patience
    public var report: Reporter

    public init(http: HTTP, apiKey: String, patience: Patience = .background, report: Reporter = Reporter()) {
        self.http = http
        self.apiKey = apiKey
        self.patience = patience
        self.report = report
    }

    /// A personal key from api.nasa.gov is a long alphanumeric string; anything else
    /// (DEMO_KEY, empty, a pasted placeholder) means the shared, rate-limited key.
    public static func isPersonal(_ key: String) -> Bool {
        key != "DEMO_KEY" && key.count >= 20 && key.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    /// GET with retries on network failures and server errors, as curl --retry does.
    func getRetrying(_ url: URL) async throws -> (Data, Int) {
        let start = Date()
        var attempt = 0
        while true {
            do {
                let (data, code) = try await http.get(url, timeout: patience.requestTimeout)
                if code >= 500 || code == 408, attempt < patience.retries,
                   Date().timeIntervalSince(start) + patience.delay < patience.maxTime {
                    attempt += 1
                    try await Task.sleep(for: .seconds(patience.delay))
                    continue
                }
                return (data, code)
            } catch let error as URLError where error.code != .cancelled {
                guard attempt < patience.retries, Date().timeIntervalSince(start) + patience.delay < patience.maxTime else {
                    throw error
                }
                attempt += 1
                try await Task.sleep(for: .seconds(patience.delay))
            }
        }
    }

    /// The raw APOD API response for query, with a readable error for rate limits and bad keys.
    func api(_ query: [URLQueryItem]) async throws -> Data {
        var parts = URLComponents(string: "https://api.nasa.gov/planetary/apod")!
        parts.queryItems = query + [URLQueryItem(name: "api_key", value: apiKey)]
        let data: Data, code: Int
        do {
            (data, code) = try await getRetrying(parts.url!)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            report.problem("NASA API unreachable")
            throw APODError.message("NASA API unreachable")
        }
        switch code {
        case 200:
            return data
        case 429:
            let m = "NASA API rate limit reached" + (Self.isPersonal(apiKey) ? "" : " (shared DEMO_KEY); add your own key in Settings")
            report.problem(m)
            throw APODError.message(m)
        default:
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let detail = (json?["msg"] as? String) ?? ((json?["error"] as? [String: Any])?["message"] as? String)
            let m = "NASA API error \(code)" + (detail.map { ": \($0)" } ?? "")
            report.problem(m)
            throw APODError.message(m)
        }
    }

    /// API entries for query, keeping still images, videos and entries that need pageEntry;
    /// if the API fails, {"date": ...} stubs for dates instead.
    public func entries(_ query: [URLQueryItem], dates: [String]) async throws -> [APODEntry] {
        if let data = try? await api(query) {
            if let parsed = Self.parse(data) {
                return parsed.filter { $0.needsPage || $0.mediaType == "image" || $0.isVideo }
            }
            report.problem("NASA API returned an unreadable response")
        }
        try Task.checkCancellation()
        report.stage("trying the APOD website instead")
        report.forgetProblems()
        return dates.map { APODEntry(date: $0) }
    }

    /// One entry or an array of them; nil when the response isn't that.
    static func parse(_ data: Data) -> [APODEntry]? {
        let decoder = JSONDecoder()
        if let list = try? decoder.decode([APODEntry].self, from: data) { return list }
        if let one = try? decoder.decode(APODEntry.self, from: data) { return [one] }
        return nil
    }

    /// The APOD entry for date read from its science.nasa.gov page, in the API's format.
    public func pageEntry(_ date: String) async throws -> APODEntry {
        guard let day = APODDate.parse(date) else { throw APODError.message("not a date: \(date)") }
        let data: Data, code: Int
        do {
            (data, code) = try await getRetrying(URL(string: "https://science.nasa.gov/apod/?date=\(date)")!)
        } catch {
            report.problem("APOD page for \(date) unreachable")
            throw APODError.message("APOD page for \(date) unreachable")
        }
        guard code == 200, let entry = Self.scrape(String(decoding: data, as: UTF8.self), date: date, day: day) else {
            report.problem("no APOD entry for \(date) on the website")
            throw APODError.message("no APOD entry for \(date) on the website")
        }
        return entry
    }

    /// The entry in a science.nasa.gov APOD page, or nil if the page isn't that day's.
    /// The patterns depend on the site's markup; check them first when the fallback breaks.
    static func scrape(_ html: String, date: String, day: Date) -> APODEntry? {
        let h = html.replacingOccurrences(of: "\n", with: " ")
        // The page's og:title starts with this; unpublished dates show the landing page, whose og:title has no date.
        let want = APODDate.titleFormatter.string(from: day)
        guard (grab(h, #"<meta property="og:title" content="([^"]*)""#) ?? "").hasPrefix(want) else { return nil }
        // The picture (or video) is the last media element before the heading; og:image is
        // sometimes a generic thumbnail. The original sits under content/dam without the query.
        let beforeHeading = h.components(separatedBy: #"<h1 class="display-48"#)[0]
        let hero = matches(beforeHeading, #"<img [^>]*?src="[^"]*"|<iframe|<video"#).last ?? ""
        let img = grab(hero, #"src="(https://assets\.science\.nasa\.gov/[^"?]*)"#)
            .map { replaceFirst($0, "/dynamicimage/assets/", "/content/dam/") }
        guard let title = grab(h, #"<h1 class="display-48[^>]*>(.*?)</h1>"#).map(text) else { return nil }
        let explanation = grab(h, #"media-detail-hero__description">(.*?)</p>"#)
            .map { regexReplace(text($0), "^Explanation: ?", "") }
        let credit = grab(h, #">[^<]*Credit[^<]*</th>\s*<td[^>]*>(.*?)</td>"#)
            .map { regexReplace(text($0), "^(Image |Video )?Credit( & Copyright)?: ?", "") }
        let media = hero.hasPrefix("<iframe") || hero.hasPrefix("<video") ? "video" : img != nil ? "image" : "other"
        return APODEntry(date: date, title: title, explanation: explanation, copyright: credit,
                         mediaType: media, url: img, hdurl: img)
    }

    /// The entry itself, or its pageEntry when the API's copy is bad. Fails unless it is a
    /// still image from NASA over https, or a video (which show only notes for the popover).
    public func resolve(_ entry: APODEntry) async throws -> APODEntry? {
        let entry = entry.needsPage ? try await pageEntry(entry.date) : entry
        return Self.acceptable(entry) ? entry : nil
    }

    /// Only https from NASA's own hosts: the URL comes from a web page.
    static func acceptable(_ entry: APODEntry) -> Bool {
        if entry.isVideo { return true }
        guard entry.mediaType == "image", let url = entry.bestURL else { return false }
        return url.range(of: #"^https://([a-z0-9-]+\.)*nasa\.gov/"#, options: .regularExpression) != nil
    }
}

// MARK: - Text from HTML

func grab(_ s: String, _ pattern: String) -> String? {
    guard let re = try? NSRegularExpression(pattern: pattern),
          let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
          m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: s) else { return nil }
    return String(s[r])
}

func matches(_ s: String, _ pattern: String) -> [String] {
    guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
    return re.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap { Range($0.range, in: s).map { String(s[$0]) } }
}

func regexReplace(_ s: String, _ pattern: String, _ template: String) -> String {
    guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
    return re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
}

func replaceFirst(_ s: String, _ target: String, _ replacement: String) -> String {
    guard let r = s.range(of: target) else { return s }
    return s.replacingCharacters(in: r, with: replacement)
}

/// Plain text from a snippet of the page's HTML.
func text(_ html: String) -> String {
    var s = regexReplace(html, "<br[^>]*>", " ")
    s = regexReplace(s, "<[^>]*>", "")
    if let re = try? NSRegularExpression(pattern: "&#([0-9]+);") {
        for m in re.matches(in: s, range: NSRange(s.startIndex..., in: s)).reversed() {
            guard let whole = Range(m.range, in: s), let digits = Range(m.range(at: 1), in: s),
                  let n = UInt32(s[digits]), let scalar = Unicode.Scalar(n) else { continue }
            s.replaceSubrange(whole, with: String(Character(scalar)))
        }
    }
    for (entity, char) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&nbsp;", " ")] {
        s = s.replacingOccurrences(of: entity, with: char)
    }
    s = regexReplace(s, #"\s+"#, " ")
    s = regexReplace(s, " ([,.;:!?])", "$1")
    return s.trimmingCharacters(in: .init(charactersIn: " "))
}

// MARK: - Dates

public enum APODDate {
    /// Date arithmetic on calendar days, free of time zones and daylight saving.
    static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = calendar
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = calendar.timeZone
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static let titleFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = calendar
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = calendar.timeZone
        f.dateFormat = "'APOD: 'yyyy MMMM d' '"
        return f
    }()

    public static func parse(_ s: String) -> Date? {
        guard s.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}$"#, options: .regularExpression) != nil,
              let d = formatter.date(from: s), formatter.string(from: d) == s else { return nil }
        return d
    }

    public static func string(_ d: Date) -> String { formatter.string(from: d) }

    public static func adding(_ days: Int, to s: String) -> String {
        string(calendar.date(byAdding: .day, value: days, to: parse(s)!)!)
    }

    /// The day APOD is on at `now`: it changes at midnight US Eastern time.
    public static func today(_ now: Date = Date()) -> String {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        let parts = c.dateComponents([.year, .month, .day], from: now)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }

    /// The local calendar day, for "one random picture a day".
    public static func localDay(_ now: Date = Date()) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: now)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }

    public static func days(from a: String, to b: String) -> Int {
        calendar.dateComponents([.day], from: parse(a)!, to: parse(b)!).day!
    }
}
