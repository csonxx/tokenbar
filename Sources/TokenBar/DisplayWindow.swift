import Foundation

/// Time window over which the dashboard aggregates and renders data.
/// Drives the pill-bar selector at the top of the panel and the menu-bar
/// headline numbers.
enum DisplayWindow: String, CaseIterable, Identifiable, Codable {
    case today
    case last24h
    case last3d
    case last7d
    case last15d
    case last30d
    case all

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .today: return "今日"
        case .last24h: return "近 24h"
        case .last3d: return "近 3 天"
        case .last7d: return "近 7 天"
        case .last15d: return "近 15 天"
        case .last30d: return "近 30 天"
        case .all: return "全部"
        }
    }

    var shortName: String {
        switch self {
        case .today: return "今天"
        case .last24h: return "24h"
        case .last3d: return "3D"
        case .last7d: return "7D"
        case .last15d: return "15D"
        case .last30d: return "30D"
        case .all: return "All"
        }
    }

    /// Returns the inclusive lower bound (in the user's local calendar).
    /// `nil` means "no lower bound" (used by `.all`).
    func startDate(now: Date = Date(), calendar: Calendar = .current) -> Date? {
        switch self {
        case .today:
            return calendar.startOfDay(for: now)
        case .last24h:
            return now.addingTimeInterval(-24 * 3600)
        case .last3d:
            return calendar.date(byAdding: .day, value: -3, to: calendar.startOfDay(for: now))
        case .last7d:
            return calendar.date(byAdding: .day, value: -7, to: calendar.startOfDay(for: now))
        case .last15d:
            return calendar.date(byAdding: .day, value: -15, to: calendar.startOfDay(for: now))
        case .last30d:
            return calendar.date(byAdding: .day, value: -30, to: calendar.startOfDay(for: now))
        case .all:
            return nil
        }
    }

    /// Granularity used for the trend chart. Sub-day windows stay hourly,
    /// multi-day windows are daily.
    var bucketGranularity: TrendBucket.Granularity {
        switch self {
        case .today, .last24h: return .hour
        default: return .day
        }
    }

    /// Approximate number of buckets shown on the trend chart.
    var bucketCount: Int {
        switch self {
        case .today: return 24
        case .last24h: return 24
        case .last3d: return 18       // 3d * 6 buckets/day at 4-hour steps
        case .last7d: return 14
        case .last15d: return 15
        case .last30d: return 30
        case .all: return 30          // capped; see TrendBuilder
        }
    }

    static let `default`: DisplayWindow = .today
}

/// One data point on the trend chart.
struct TrendBucket: Identifiable, Hashable {
    enum Granularity: Hashable { case hour, day }

    let id: Date
    let granularity: Granularity
    let aggregate: DailyAggregate

    var sortKey: Date { id }
}

/// Persists the user's preferred window across launches.
struct DisplayWindowPrefs: Codable {
    var window: DisplayWindow
    static let `default` = DisplayWindowPrefs(window: .default)
    static let storeURL: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent("TokenBar/display_window.json")
    }()

    static func load() -> DisplayWindowPrefs {
        guard let data = try? Data(contentsOf: storeURL),
              let p = try? JSONDecoder().decode(DisplayWindowPrefs.self, from: data) else {
            return .default
        }
        return p
    }

    func save() {
        try? FileManager.default.createDirectory(at: Self.storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(self) {
            try? data.write(to: Self.storeURL, options: .atomic)
        }
    }
}
