import Foundation
import Testing

@testable import TarteletteCore

/// Values `--provisioning-opts` can't carry are left out of argv; callers must learn about them
/// through `validationProblems` and block the launch instead of provisioning without them.
@Suite("Run option validation problems")
struct RunOptionsValidationProblemsTests {
  @Test func commaInPasswordIsReportedNotSilentlyDropped() {
    var options = RunOptions(name: "vm")
    options.provisioning = .init(username: "ada", password: "se,cret")

    #expect(options.validationProblems.count == 1)
    #expect(options.validationProblems.first?.contains("Password") == true)
    #expect(options.isLaunchable == false)
    // Still never emitted as a corrupted option list.
    #expect(!options.arguments.joined(separator: " ").contains("se,cret"))
  }

  @Test func validOptionsHaveNoProblems() {
    var options = RunOptions(name: "vm")
    #expect(options.validationProblems.isEmpty)
    #expect(options.isLaunchable)
    options.provisioning = .init(fullName: "Ada Lovelace", username: "ada", password: "p=ss")
    #expect(options.validationProblems.isEmpty)
    #expect(options.isLaunchable)
  }

  @Test func everyUnrepresentableFieldIsNamed() {
    var options = RunOptions(name: "vm")
    options.provisioning = .init(fullName: "Lovelace, Ada", username: "a,da", password: "x")
    let problem = options.validationProblems.joined()
    #expect(problem.contains("Full name"))
    #expect(problem.contains("Username"))
    #expect(!problem.contains("Password"))
  }
}
