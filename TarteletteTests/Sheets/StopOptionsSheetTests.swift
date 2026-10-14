import Testing
import TarteletteKit

@testable import Tartelette

@Suite("Stop options preview")
struct StopOptionsSheetTests {
  @Test func macOSShutDownShowsTheGuestAgentRequestAndItsFallback() {
    #expect(
      StopOptionsSheet.shutdownCommandLine(vmName: "dev", os: .macOS, pid: 4242) == """
        tart exec dev /usr/bin/osascript -e 'tell application "loginwindow" to «event aevtshut»'  # asks “dev” to shut down
        kill -USR2 4242  # if the guest agent doesn't answer
        """)
  }

  @Test func macOSShutDownWithoutAKnownProcessShowsOnlyTheGuestAgentRequest() {
    #expect(
      StopOptionsSheet.shutdownCommandLine(vmName: "dev", os: .macOS, pid: nil)
        == "tart exec dev /usr/bin/osascript -e 'tell application \"loginwindow\" to «event aevtshut»'  # asks “dev” to shut down"
    )
  }

  @Test func otherGuestsShutDownWithSIGUSR2() {
    #expect(StopOptionsSheet.shutdownCommandLine(vmName: "ubuntu", os: .linux, pid: 4242) == "kill -USR2 4242  # asks “ubuntu” to shut down")
    #expect(StopOptionsSheet.shutdownCommandLine(vmName: "ubuntu", os: .unknown, pid: 4242) == "kill -USR2 4242  # asks “ubuntu” to shut down")
    #expect(StopOptionsSheet.shutdownCommandLine(vmName: "ubuntu", os: .linux, pid: nil) == nil)
  }
}
