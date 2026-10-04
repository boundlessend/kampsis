import AppKit
import Observation
import os

/// проверка новых выпусков на GitHub: вручную из меню или раз в сутки, если пользователь включил
@MainActor @Observable final class UpdateChecker {
    private static let log = Logger(subsystem: "io.github.boundlessend.kampsis", category: "updates")
    private static let automaticKey = "automatic-update-checks"
    private static let lastCheckKey = "last-update-check"
    private static let checkInterval: TimeInterval = 24 * 60 * 60
    private static let wakeInterval: Duration = .seconds(60 * 60)

    private(set) var checking = false
    private(set) var checksAutomatically: Bool
    private(set) var availableRelease: PublishedRelease?

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
        guard store.object(forKey: Self.automaticKey) != nil else {
            guard !isLoginLaunch(NSAppleEventManager.shared().currentAppleEvent) else { return }
            Task { askAboutAutomaticChecks() }
            return
        }
        if checksAutomatically { scheduleChecks() }
    }

    /// при первом запуске пользователь сам решает, обращаться ли приложению к GitHub без его команды
    private func askAboutAutomaticChecks() {
        let alert = NSAlert()
        alert.messageText = String(localized: "Check for updates automatically?")
        alert.informativeText = String(localized: "Once a day \(AppIdentity.name) asks GitHub whether a new version is out and lets you know. You can change this later in General Settings.")
        alert.addButton(withTitle: String(localized: "Check Daily"))
        alert.addButton(withTitle: String(localized: "Don’t Check"))
        NSApp.activate()
        setChecksAutomatically(alert.runModal() == .alertFirstButtonReturn)
    }

    func setChecksAutomatically(_ enabled: Bool) {
        checksAutomatically = enabled
        store.set(enabled, forKey: Self.automaticKey)
        schedule?.cancel()
        schedule = nil
        if enabled { scheduleChecks() }
    }

    func stop() {
        schedule?.cancel()
        schedule = nil
    }

    func openAvailableRelease() {
        guard let availableRelease else { return }
        NSWorkspace.shared.open(availableRelease.pageURL)
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
            _ = try await fetchVerdict()
        } catch is CancellationError {
            return
        } catch {
            Self.log.warning("background update check failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func fetchVerdict() async throws -> UpdateVerdict {
        let latest = try await releases.get().latest()
        try Task.checkCancellation()
        let verdict = try updateVerdict(installed: installedVersion, latest: latest)
        store.set(Date(), forKey: Self.lastCheckKey)
        if case .available = verdict { availableRelease = latest } else { availableRelease = nil }
        return verdict
    }

    private func presentVerdict(_ verdict: UpdateVerdict) {
        let alert = NSAlert()
        switch verdict {
        case let .available(version, release):
            alert.messageText = String(localized: "Version \(version.description) is available")
            let notes = release.notes.map { "\n\n" + String($0.prefix(600)) } ?? ""
            alert.informativeText = String(localized: "You have \(installedVersion) installed.") + notes
            alert.addButton(withTitle: String(localized: "Open Release Page"))
            alert.addButton(withTitle: String(localized: "Later"))
            NSApp.activate()
            if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(release.pageURL) }
        case let .upToDate(version):
            alert.messageText = String(localized: "No Updates")
            alert.informativeText = String(localized: "You have the latest version, \(version.description).")
            NSApp.activate()
            alert.runModal()
        case let .aheadOfPublished(installed, published):
            alert.messageText = String(localized: "No Updates")
            alert.informativeText = String(localized: "This build (\(installed.description)) is newer than the latest release, \(published.description).")
            NSApp.activate()
            alert.runModal()
        }
    }

    private func presentFailure(_ error: any Error) {
        Self.log.error("update check failed: \(error.localizedDescription, privacy: .public)")
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Couldn’t Check for Updates")
        alert.informativeText = error.localizedDescription
        NSApp.activate()
        alert.runModal()
    }
}
