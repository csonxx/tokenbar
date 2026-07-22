import Foundation

protocol TokenSource {
    var tool: ToolKind { get }
    func collect() async throws -> SourceResult
}

struct SourceResult {
    let samples: [TokenSample]
    let fileCount: Int
    let note: String?

    static func empty(note: String? = nil) -> SourceResult {
        SourceResult(samples: [], fileCount: 0, note: note)
    }
}

enum TokenSourceError: Error, CustomStringConvertible {
    case missingHome
    case unreadable(String)

    var description: String {
        switch self {
        case .missingHome: return "无法定位用户主目录"
        case .unreadable(let p): return "不可读: \(p)"
        }
    }
}
