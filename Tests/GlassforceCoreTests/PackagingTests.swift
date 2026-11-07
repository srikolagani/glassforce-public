import Foundation
import Testing
@testable import GlassforceCore

@Suite("Unsigned release and personal tap")
struct PackagingTests {
    private func repoFile(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    @Test func releaseIsAdHocUnlessEnvVarsAreSet() throws {
        let script = try repoFile("scripts/release.sh")
        #expect(script.contains("codesign --force --sign -"))
        #expect(script.contains("GLASSFORCE_SIGN_IDENTITY"))
        #expect(script.contains("GLASSFORCE_NOTARY_PROFILE"))
        #expect(!script.contains("find-identity"), "do not pick a Developer ID out of the keychain")
        #expect(script.contains("notarization needs GLASSFORCE_SIGN_IDENTITY"))
    }

    @Test func caskIsOnSrisTapAndReadmeLeadsWithBrew() throws {
        let cask = try repoFile("packaging/homebrew/glassforce.rb")
        let readme = try repoFile("README.md")
        #expect(cask.contains("srikolagani/tap"))
        #expect(cask.contains("Not for homebrew/cask"))
        #expect(cask.contains("Do not install with --no-quarantine"))
        #expect(readme.contains("Open Anyway"))
        #expect(readme.contains("ad-hoc signed"))
        #expect(!readme.contains("--no-quarantine"))
        #expect(!readme.contains("homebrew/cask"))
        #expect(!readme.localizedLowercase.contains("disable gatekeeper"))
    }
}
