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

    @Test func qaPanelBundleIsSealedAfterThePlistExists() throws {
        let script = try repoFile("scripts/build-qa-panel.sh")
        let provenance = script.range(of: "scripts/source-provenance.sh")
        let plist = script.range(of: "Contents/Info.plist")
        let remove = script.range(of: "codesign --remove-signature")
        let seal = script.range(of: "codesign --force --sign - --identifier")
        let verify = script.range(of: "codesign --verify --strict")
        #expect(provenance != nil && plist != nil && remove != nil && seal != nil && verify != nil)
        if let provenance, let plist, let remove, let seal, let verify {
            #expect(remove.lowerBound < plist.lowerBound)
            #expect(plist.lowerBound < seal.lowerBound)
            #expect(seal.lowerBound < verify.lowerBound)
            #expect(provenance.lowerBound < seal.lowerBound)
        }
        #expect(script.contains("GlassforceSourceSHA"))
        #expect(script.contains("GlassforceSourceDirty"))
        #expect(script.contains("com.srikolagani.glassforce.qa"))
        #expect(script.contains("Contents/_CodeSignature/CodeResources") || script.contains("Seal the .app"))
        #expect(!script.contains("spctl"))
        #expect(!script.contains("open "))
    }
}
