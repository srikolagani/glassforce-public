import Foundation
import Testing
@testable import GlassforceCore

@Suite("Built app source metadata")
struct SourceProvenanceTests {
    private var script: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("scripts/source-provenance.sh")
    }

    @Test func rejectsInventedOrShortSHAs() {
        #expect(SourceProvenance.resolve(head: nil, porcelain: "") == SourceProvenance(sha: "", dirty: .unknown))
        #expect(SourceProvenance.resolve(head: "abc", porcelain: "") == SourceProvenance(sha: "", dirty: .unknown))
        #expect(SourceProvenance.resolve(head: String(repeating: "A", count: 40), porcelain: "") == SourceProvenance(sha: "", dirty: .unknown))
        #expect(SourceProvenance.resolve(head: "deadbeef", porcelain: "M file").sha.isEmpty)
        let real = String(repeating: "a", count: 40)
        #expect(SourceProvenance.resolve(head: real, porcelain: "") == SourceProvenance(sha: real, dirty: .clean))
        #expect(SourceProvenance.resolve(head: real, porcelain: " M README.md") == SourceProvenance(sha: real, dirty: .dirty))
        #expect(SourceProvenance.resolve(head: real, porcelain: nil, statusFailed: true) == SourceProvenance(sha: real, dirty: .unknown))
    }

    @Test func cleanCommitRecordsThatExactHead() throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let head = try git(repo, ["rev-parse", "HEAD"])
        let meta = try runScript(repo)
        #expect(meta.sha == head)
        #expect(meta.dirty == .clean)
        #expect(meta.sha.count == 40)
    }

    @Test func uncommittedEditKeepsTheSameSHAAndMarksDirty() throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let head = try git(repo, ["rev-parse", "HEAD"])
        try "changed\n".write(to: repo.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        let meta = try runScript(repo)
        #expect(meta.sha == head)
        #expect(meta.dirty == .dirty)
        let porcelain = try git(repo, ["status", "--porcelain"])
        #expect(!porcelain.isEmpty)
    }

    @Test func directoryThatIsNotARepoDoesNotInventACommit() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("gf-nongit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let meta = try runScript(dir)
        #expect(meta.sha.isEmpty)
        #expect(meta.dirty == .unknown)
    }

    @Test func parserDropsANonCommitSHA() {
        let parsed = SourceProvenance.parse(scriptOutput: "GlassforceSourceSHA not-a-commit\nGlassforceSourceDirty false\n")
        #expect(parsed.sha.isEmpty)
        #expect(parsed.dirty == .unknown)
    }

    private func makeRepo() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("gf-prov-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try git(dir, ["init"])
        try "hello\n".write(to: dir.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try git(dir, ["add", "README.md"])
        try git(dir, ["-c", "user.email=provenance@example.com", "-c", "user.name=Provenance Test", "commit", "-m", "init"])
        return dir
    }

    @discardableResult
    private func git(_ dir: URL, _ args: [String]) throws -> String {
        try run("/usr/bin/git", args, dir)
    }

    private func runScript(_ dir: URL) throws -> SourceProvenance {
        let output = try run("/bin/bash", [script.path, dir.path], dir)
        return SourceProvenance.parse(scriptOutput: output)
    }

    private func run(_ launch: String, _ args: [String], _ dir: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launch)
        process.arguments = args
        process.currentDirectoryURL = dir
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else {
            throw ProvenanceTestError.command(launch, process.terminationStatus, text)
        }
        return text
    }

    private enum ProvenanceTestError: Error {
        case command(String, Int32, String)
    }
}
