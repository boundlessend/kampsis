import Foundation

/// номер версии вида 1.2.3; тег выпуска может начинаться с «v»
struct SemanticVersion: Comparable, CustomStringConvertible, Sendable {
    let parts: [Int]

    init?(_ text: String) {
        let trimmed = text.hasPrefix("v") ? String(text.dropFirst()) : text
        let numbers = trimmed.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !numbers.isEmpty, numbers.count <= 4, numbers.allSatisfy({ ($0 ?? -1) >= 0 }) else { return nil }
        parts = numbers.compactMap { $0 }
    }

    var description: String { parts.map(String.init).joined(separator: ".") }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        let width = max(lhs.parts.count, rhs.parts.count)
        let left = lhs.parts + Array(repeating: 0, count: width - lhs.parts.count)
        let right = rhs.parts + Array(repeating: 0, count: width - rhs.parts.count)
        return left.lexicographicallyPrecedes(right)
    }

    static func == (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }
}

/// последний опубликованный выпуск в том виде, в каком его отдаёт GitHub
struct PublishedRelease: Decodable, Equatable, Sendable {
    let tagName: String
    let pageURL: URL
    let notes: String?

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case pageURL = "html_url"
        case notes = "body"
    }
}

enum UpdateVerdict: Equatable, Sendable {
    case upToDate(SemanticVersion)
    case available(SemanticVersion, PublishedRelease)
    /// установленная сборка новее опубликованной, так бывает у разработческих сборок
    case aheadOfPublished(installed: SemanticVersion, published: SemanticVersion)
}

enum ReleaseCheckFailure: LocalizedError, Equatable {
    case unreadableVersion(String)

    var errorDescription: String? {
        switch self {
        case let .unreadableVersion(text): "Не удалось разобрать номер версии «\(text)»."
        }
    }
}

func updateVerdict(installed: String, latest: PublishedRelease) throws(ReleaseCheckFailure) -> UpdateVerdict {
    guard let current = SemanticVersion(installed) else { throw .unreadableVersion(installed) }
    guard let published = SemanticVersion(latest.tagName) else { throw .unreadableVersion(latest.tagName) }
    if published > current { return .available(published, latest) }
    if published < current { return .aheadOfPublished(installed: current, published: published) }
    return .upToDate(current)
}
