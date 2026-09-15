import AppKit
import Observation
import os

/// проверка новых выпусков на GitHub: вручную из меню или раз в сутки, если пользователь включил
@MainActor @Observable final class UpdateChecker {
    private static let log = Logger(subsystem: "local.boundlessend.lidfold", category: "updates")
    private static let automaticKey = "automatic-update-checks"
    private static let lastCheckKey = "last-update-check"
    private static let checkInterval: TimeInterval = 24 * 60 * 60
    private static let wakeInterval: Duration = .seconds(60 * 60)

    private(set) var checking = false
    private(set) var checksAutomatically: Bool

    @ObservationIgnored private let releases: Result<GitHubReleases, GitHubReleasesFailure>
    @ObservationIgnored private let installedVersion: String
    @ObservationIgnored private let store: UserDefaults
    @ObservationIgnored private var schedule: Task<Void, Never>?

    init(releases: Result<GitHubReleases, GitHubReleasesFailure>, installedVersion: String, store: UserDefaults) {
        self.releases = releases
        self.installedVersion = installedVersion
        self.store = store
        checksAutomatically = store.bool(forKey: Self.automaticKey)
    }

    func start() {
        if checksAutomatically { scheduleChecks() }
    }

    func setChecksAutomatically(_ enabled: Bool) {
        checksAutomatically = enabled
        store.set(enabled, forKey: Self.automaticKey)
        schedule?.cancel()
        schedule = nil
        if enabled { scheduleChecks() }
    }

    /// проверка по просьбе пользователя: показывает любой итог, включая ошибку
    func checkFromMenu() {
        guard !checking else { return }
        checking = true
        Task {
            defer { checking = false }
            do {
                presentVerdict(try await fetchVerdict())
            } catch {
                presentFailure(error)
            }
        }
    }

    private func scheduleChecks() {
        schedule = Task { [weak self] in
            while !Task.isCancelled {
                await self?.checkIfDue()
                do { try await Task.sleep(for: Self.wakeInterval) } catch { return }
            }
        }
    }

    /// фоновая проверка беспокоит пользователя только новой версией, сбои уходят в лог
    private func checkIfDue() async {
        if let last = store.object(forKey: Self.lastCheckKey) as? Date,
           Date().timeIntervalSince(last) < Self.checkInterval { return }
        guard !checking else { return }
        checking = true
        defer { checking = false }
        do {
            let verdict = try await fetchVerdict()
            if case .available = verdict { presentVerdict(verdict) }
        } catch {
            Self.log.warning("background update check failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func fetchVerdict() async throws -> UpdateVerdict {
        let latest = try await releases.get().latest()
        store.set(Date(), forKey: Self.lastCheckKey)
        return try updateVerdict(installed: installedVersion, latest: latest)
    }

    private func presentVerdict(_ verdict: UpdateVerdict) {
        let alert = NSAlert()
        switch verdict {
        case let .available(version, release):
            alert.messageText = "Вышла версия \(version)"
            let notes = release.notes.map { "\n\n" + String($0.prefix(600)) } ?? ""
            alert.informativeText = "Сейчас установлена \(installedVersion).\(notes)"
            alert.addButton(withTitle: "Открыть страницу выпуска")
            alert.addButton(withTitle: "Позже")
            NSApp.activate()
            if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(release.pageURL) }
        case let .upToDate(version):
            alert.messageText = "Обновлений нет"
            alert.informativeText = "Установлена последняя версия \(version)."
            NSApp.activate()
            alert.runModal()
        case let .aheadOfPublished(installed, published):
            alert.messageText = "Обновлений нет"
            alert.informativeText = "Эта сборка (\(installed)) новее последнего выпуска \(published)."
            NSApp.activate()
            alert.runModal()
        }
    }

    private func presentFailure(_ error: any Error) {
        Self.log.error("update check failed: \(error.localizedDescription, privacy: .public)")
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Не удалось проверить обновления"
        alert.informativeText = error.localizedDescription
        NSApp.activate()
        alert.runModal()
    }
}
