import Foundation
import Testing
@testable import Kampsis

struct ReleaseTests {
    private func release(_ tag: String) -> PublishedRelease {
        PublishedRelease(tagName: tag, pageURL: URL(string: "https://github.com/boundlessend/kampsis/releases/tag/\(tag)")!,
                         notes: nil)
    }

    @Test func versionsCompareNumericallyWithOptionalPrefix() throws {
        let parse = { (text: String) throws -> SemanticVersion in try #require(SemanticVersion(text)) }
        #expect(try parse("v0.10.0") > parse("0.9.9"))
        #expect(try parse("1.0") == parse("1.0.0"))
        #expect(try parse("v2.1.3").description == "2.1.3")
        for broken in ["", "v", "1..2", "1.2.x", "-1.0", "1.2.3-beta", "1.2.3.4.5"] {
            #expect(SemanticVersion(broken) == nil, "«\(broken)»")
        }
    }

    @Test func verdictComparesInstalledWithPublished() throws {
        #expect(try updateVerdict(installed: "0.1.0", latest: release("v0.1.0")) == .upToDate(SemanticVersion("0.1.0")!))
        #expect(try updateVerdict(installed: "0.1.0", latest: release("v0.2.0"))
            == .available(SemanticVersion("0.2.0")!, release("v0.2.0")))
        #expect(try updateVerdict(installed: "0.3.0", latest: release("v0.2.0"))
            == .aheadOfPublished(installed: SemanticVersion("0.3.0")!, published: SemanticVersion("0.2.0")!))
        #expect(throws: ReleaseCheckFailure.unreadableVersion("nightly")) {
            try updateVerdict(installed: "0.1.0", latest: release("nightly"))
        }
    }

    @Test func githubResponseDecodes() throws {
        let body = Data("""
        {"url": "https://api.github.com/repos/boundlessend/kampsis/releases/1", "tag_name": "v0.2.0",
         "html_url": "https://github.com/boundlessend/kampsis/releases/tag/v0.2.0", "body": "Исправления", "draft": false}
        """.utf8)
        let decoded = try JSONDecoder().decode(PublishedRelease.self, from: body)
        #expect(decoded.tagName == "v0.2.0")
        #expect(decoded.notes == "Исправления")
        #expect(decoded.pageURL.host() == "github.com")
    }

    @Test func bundleCarriesPrivacyManifest() throws {
        let url = try #require(Bundle.main.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"),
                               "манифест приватности не попал в сборку")
        let manifest = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), options: [], format: nil)
        let fields = try #require(manifest as? [String: Any])
        #expect(fields["NSPrivacyTracking"] as? Bool == false)
        #expect((fields["NSPrivacyTrackingDomains"] as? [Any])?.isEmpty == true)
        #expect((fields["NSPrivacyCollectedDataTypes"] as? [Any])?.isEmpty == true)
        #expect((fields["NSPrivacyAccessedAPITypes"] as? [Any])?.isEmpty == false, "причины доступа к API не указаны")
    }

    @Test func repositoryMustLookLikeOwnerAndName() {
        #expect(throws: GitHubReleasesFailure.self) { try GitHubReleases(repository: "not a repo", session: .shared) }
        #expect(throws: GitHubReleasesFailure.self) { try GitHubReleases(repository: "owner/name/extra", session: .shared) }
        #expect(throws: Never.self) { try GitHubReleases(repository: AppIdentity.releasesRepository, session: .shared) }
    }
}
