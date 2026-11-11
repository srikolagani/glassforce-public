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

    @Test func releaseBuilderCannotAutoSelectSigningIdentity() throws {
        let script = try repoFile("scripts/release.sh")
        #expect(script.contains("SIGN_IDENTITY=\"${GLASSFORCE_SIGN_IDENTITY:--}\""))
        #expect(script.contains("GLASSFORCE_SIGN_IDENTITY=\"$SIGN_IDENTITY\" scripts/build-app.sh release"))
        #expect(script.contains("if [[ \"$SIGN_IDENTITY\" != \"-\" ]]; then"))
    }

    @Test func notarizationWithAdHocIdentityFailsBeforeBuilding() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [root.appendingPathComponent("scripts/release.sh").path]
        var env = ProcessInfo.processInfo.environment
        env["GLASSFORCE_SIGN_IDENTITY"] = "-"
        env["GLASSFORCE_NOTARY_PROFILE"] = "invalid-test-profile-never-used"
        process.environment = env
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        #expect(process.terminationStatus == 1)
        #expect(output.contains("notarization needs GLASSFORCE_SIGN_IDENTITY"))
        #expect(!output.contains("Building Release"))
    }

    @Test func caskTemplateKeepsQuarantineAndReadmeExplainsInstallStatus() throws {
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

    @Test func packagingKeepsSourceCleanAndProvidesDragInstall() throws {
        let script = try repoFile("scripts/release.sh")
        #expect(script.contains("release packaging requires a clean Git checkout"))
        #expect(script.contains("release packaging refuses local packaged-app identity overrides"))
        #expect(script.contains("Path(\"build/release/glassforce.rb\").write_text(body)"))
        #expect(!script.contains("Path(\"packaging/homebrew/glassforce.rb\").write_text"))
        #expect(script.contains("ln -s /Applications"))
        #expect(script.contains("release-metadata.json"))
        #expect(script.contains("codesign --force --sign -"))
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
