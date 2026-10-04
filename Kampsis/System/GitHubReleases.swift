import Foundation
import os

enum GitHubReleasesFailure: LocalizedError {
    case invalidRepository(String)
    case releaseUnavailable(repository: String)
    case rateLimited
    case accessDenied
    case unexpectedStatus(Int)
    case invalidResponse
    case network(URLError.Code)

    var errorDescription: String? {
        switch self {
        case let .invalidRepository(repository):
            String(localized: "The releases repository “\(repository)” is invalid.")
        case let .releaseUnavailable(repository):
            String(localized: "The latest release in \(repository) isn’t publicly available. The repository may be private or have no published release. Try again later.")
        case .rateLimited:
            String(localized: "GitHub’s request limit has been reached. Wait a while, then check again.")
        case .accessDenied:
            String(localized: "GitHub denied access to the release information. Try again later.")
        case let .unexpectedStatus(status):
            String(localized: "GitHub couldn’t provide release information (HTTP \(status)). Try again later.")
        case .invalidResponse:
            String(localized: "GitHub returned unreadable release information. Try again later.")
        case .network(.notConnectedToInternet), .network(.networkConnectionLost):
            String(localized: "The update check lost its internet connection. Check your connection and try again.")
        case .network(.timedOut):
            String(localized: "GitHub didn’t respond in time. Try again later.")
        case .network:
            String(localized: "Couldn’t connect to GitHub. Check your connection and try again.")
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

    /// принимает репозиторий в формате владелец/имя
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
            try Task.checkCancellation()
            do {
                let release = try await fetch(request)
                try Task.checkCancellation()
                return release
            } catch let failure as GitHubReleasesFailure {
                guard case let .unexpectedStatus(status) = failure, status >= 500, attempt < Self.attempts else {
                    throw failure
                }
                Self.log.warning("releases request retry: attempt=\(attempt, privacy: .public) status=\(status, privacy: .public)")
            } catch let failure as URLError {
                if failure.code == .cancelled { throw CancellationError() }
                guard attempt < Self.attempts else { throw GitHubReleasesFailure.network(failure.code) }
                Self.log.warning("releases request retry: attempt=\(attempt, privacy: .public) error=\(failure.code.rawValue, privacy: .public)")
            }
            try await Task.sleep(for: .seconds(attempt * 2))
            attempt += 1
        }
    }

    private func fetch(_ request: URLRequest) async throws -> PublishedRelease {
        let (body, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw GitHubReleasesFailure.invalidResponse }
        if http.statusCode != 200 { throw releaseResponseFailure(http, repository: repository) }
        do {
            return try JSONDecoder().decode(PublishedRelease.self, from: body)
        } catch is DecodingError {
            throw GitHubReleasesFailure.invalidResponse
        }
    }
}

/// безопасное объяснение ответа API без URL и содержимого серверного ответа
func releaseResponseFailure(_ response: HTTPURLResponse, repository: String) -> GitHubReleasesFailure {
    switch response.statusCode {
    case 404: .releaseUnavailable(repository: repository)
    case 429: .rateLimited
    case 403 where response.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0": .rateLimited
    case 401, 403: .accessDenied
    default: .unexpectedStatus(response.statusCode)
    }
}
