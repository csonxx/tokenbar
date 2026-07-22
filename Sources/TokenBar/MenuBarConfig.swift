import Foundation
import SwiftUI

enum MenuBarMetric: String, CaseIterable, Codable, Identifiable {
    case totalTokens
    case billableTokens
    case cacheHit
    case calls
    case lastUpdated

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .totalTokens: return "总 token"
        case .billableTokens: return "计费 token"
        case .cacheHit: return "缓存命中"
        case .calls: return "turns"
        case .lastUpdated: return "刷新时间"
        }
    }

    var systemImage: String {
        switch self {
        case .totalTokens: return "sum"
        case .billableTokens: return "creditcard"
        case .cacheHit: return "tray.full"
        case .calls: return "bubble.left.and.bubble.right"
        case .lastUpdated: return "clock"
        }
    }

}

/// A single headline metric shown in the menu bar. Earlier versions allowed
/// selecting 0-5 metrics to concatenate, which made the status item's width
/// jump between ~2 and ~30 characters depending on what was enabled. Menu bar
/// real estate is scarce and shared with every other app's status item, so
/// this is now a single choice: one compact number, one matching icon.
struct MenuBarConfig: Codable, Equatable {
    var headline: MenuBarMetric

    static let `default` = MenuBarConfig(headline: .billableTokens)

    static func load() -> MenuBarConfig {
        let url = Self.storeURL
        guard let data = try? Data(contentsOf: url),
              let cfg = try? JSONDecoder().decode(MenuBarConfig.self, from: data) else {
            return .default
        }
        return cfg
    }

    func save() {
        let url = Self.storeURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(self) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private static var storeURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent("TokenBar/menubar_config.json")
    }
}
