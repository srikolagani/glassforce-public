import Foundation
import GlassforceCore

/// Isolated QA process. It does not read the login Keychain or the installed app's defaults.
let result = QACommandRunner.run(
    arguments: CommandLine.arguments,
    productionRoot: LocalStore.applicationSupport().directory
)
switch result {
case .success(let line):
    print(line)
    exit(0)
case .failure(let error):
    FileHandle.standardError.write(Data("GlassforceQA: \(error)\n".utf8))
    exit(2)
}
