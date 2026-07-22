import Foundation

/// User-configured connection to a locally-running CLIProxyAPI instance.
/// `CLIProxyAPISource` only scans when `baseURL` is non-empty - the app
/// doesn't guess at a proxy the user hasn't told it about.
struct CLIProxyAPIConfig: Codable, Equatable {
    var baseURL: String
    var managementKey: String

    /// Left empty so no real credential ever ships as a compiled-in default
    /// (this file is committed to source control) - both fields are entered
    /// once from the dashboard's CLIProxyAPI settings section and persisted
    /// to disk from there.
    static let `default` = CLIProxyAPIConfig(baseURL: "", managementKey: "")

    var isConfigured: Bool {
        !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Normalizes a bare `host:port` (or full URL) into an absolute base URL.
    var resolvedBaseURL: URL? {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            return URL(string: trimmed)
        }
        return URL(string: "http://\(trimmed)")
    }

    static func load() -> CLIProxyAPIConfig {
        let url = Self.storeURL
        guard let data = try? Data(contentsOf: url),
              let cfg = try? JSONDecoder().decode(CLIProxyAPIConfig.self, from: data) else {
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
        return support.appendingPathComponent("TokenBar/cliproxyapi_config.json")
    }
}
