import Foundation
import os

enum GitHubReleasesFailure: LocalizedError {
    case invalidRepository(String)
    case noPublishedRelease(repository: String)
    case unexpectedStatus(url: URL, status: Int, body: String)
    case notHTTP(url: URL)

    var errorDescription: String? {
        switch self {
        case let .invalidRepository(repository):
            String(localized: "The releases repository “\(repository)” is invalid.")
        case let .noPublishedRelease(repository):
            String(localized: "\(repository) has no published releases yet.")
        case let .unexpectedStatus(url, status, body):
            String(localized: "GitHub responded \(status) to \(url.absoluteString): \(String(body.prefix(300)))")
        case let .notHTTP(url):
            String(localized: "The response from \(url.absoluteString) isn’t HTTP.")
        }
    }
}

/// коннектор к GitHub Releases API: узнаёт последний опубликованный выпуск
final class GitHubReleases: Sendable {
    private static let log = Logger(subsystem: "io.github.boundlessend.kampsis", category: "updates")
    private static let attempts = 3

    let repository: String
    private let url: URL
    private let session: URLSession

    /// `repository` в виде владелец/имя, как в адресе на GitHub
    init(repository: String, session: URLSession) throws(GitHubReleasesFailure) {
        guard repository.wholeMatch(of: #/[A-Za-z0-9-]+/[A-Za-z0-9_.-]+/#) != nil,
              let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest") else {
            throw .invalidRepository(repository)
        }
        self.repository = repository
        self.url = url
        self.session = session
    }

    /// сетевые сбои и ответы 5xx повторяются с паузой, остальные ошибки сразу уходят вызывающему
    func latest() async throws -> PublishedRelease {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Kampsis", forHTTPHeaderField: "User-Agent")

        var attempt = 1
        while true {
            do {
                return try await fetch(request, url: url)
            } catch let failure as GitHubReleasesFailure {
                guard case let .unexpectedStatus(_, status, _) = failure, status >= 500, attempt < Self.attempts else {
                    throw failure
                }
                Self.log.warning("releases request retry: attempt=\(attempt, privacy: .public) status=\(status, privacy: .public)")
            } catch let failure as URLError {
                guard attempt < Self.attempts else { throw failure }
                Self.log.warning("releases request retry: attempt=\(attempt, privacy: .public) error=\(failure.code.rawValue, privacy: .public)")
            }
            try await Task.sleep(for: .seconds(attempt * 2))
            attempt += 1
        }
    }

    private func fetch(_ request: URLRequest, url: URL) async throws -> PublishedRelease {
        let (body, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw GitHubReleasesFailure.notHTTP(url: url) }
        switch http.statusCode {
        case 200:
            return try JSONDecoder().decode(PublishedRelease.self, from: body)
        case 404:
            throw GitHubReleasesFailure.noPublishedRelease(repository: repository)
        default:
            throw GitHubReleasesFailure.unexpectedStatus(url: url, status: http.statusCode,
                                                         body: String(decoding: body, as: UTF8.self))
        }
    }
}
