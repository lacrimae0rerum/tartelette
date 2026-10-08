import Foundation
import Testing

@testable import TarteletteCore

@Suite("Tart command rendering")
struct TartCommandTests {
  @Test func createLinuxOmitsDefaults() {
    let command = TartCommand.create(CreateOptions(name: "dev", source: .linux, diskSizeGB: 50, diskFormat: .raw))
    #expect(command.arguments == ["create", "dev", "--linux"])
  }

  @Test func createMacOSWithCustomDisk() {
    let command = TartCommand.create(
      CreateOptions(name: "mac", source: .macOS(ipsw: "latest"), diskSizeGB: 120, diskFormat: .asif))
    #expect(
      command.arguments == ["create", "mac", "--from-ipsw", "latest", "--disk-size", "120", "--disk-format", "asif"])
  }

  @Test func cloneWithAllFlags() {
    let options = CloneOptions(
      source: "ghcr.io/cirruslabs/macos-tahoe-base:latest", newName: "tahoe", insecure: true, concurrency: 8,
      deduplicate: true, stacked: true, overwrite: true, pruneLimitGB: 20)
    #expect(
      options.arguments == [
        "clone", "ghcr.io/cirruslabs/macos-tahoe-base:latest", "tahoe", "--insecure", "--concurrency", "8",
        "--deduplicate", "--stacked", "--overwrite", "--prune-limit", "20",
      ])
  }

  @Test func runDefaultIsMinimal() {
    #expect(RunOptions(name: "vm").arguments == ["run", "vm"])
  }

  @Test func runRendersEveryOption() {
    var options = RunOptions(name: "vm")
    options.display = .vnc
    options.showWindowWithVNC = true
    options.serial = true
    options.noAudio = true
    options.noUSBAccessories = true
    options.noClipboard = true
    options.recovery = true
    options.disks = [RunOptions.DiskAttachment(location: "ubuntu.iso", readOnly: true, sync: .disabled, caching: .cached)]
    options.rosettaTag = "rosetta"
    options.directories = [
      RunOptions.DirectoryShare(name: "src", path: "~/src", readOnly: true, tag: "build"),
      RunOptions.DirectoryShare(path: "/tmp"),
    ]
    options.nested = true
    options.network = .softnet(.init(allow: ["10.0.0.0/8", "192.168.0.0/16"], block: ["1.1.1.1/32"], expose: ["2222:22"]))
    options.rootDisk = .init(sync: .disabled, caching: .uncached)
    options.captureSystemKeys = true
    options.noPointer = true
    options.provisioning = .init(username: "admin", password: "secret", enablesRemoteLogin: true)

    #expect(
      options.arguments == [
        "run", "vm", "--vnc", "--graphics", "--serial", "--no-audio", "--no-usb-accessories", "--no-clipboard",
        "--recovery", "--disk", "ubuntu.iso:ro,sync=none,caching=cached", "--rosetta", "rosetta",
        "--dir", "src:~/src:ro,tag=build", "--dir", "/tmp", "--nested",
        "--net-softnet", "--net-softnet-allow", "10.0.0.0/8,192.168.0.0/16", "--net-softnet-block", "1.1.1.1/32",
        "--net-softnet-expose", "2222:22", "--root-disk-opts", "sync=none,caching=uncached",
        "--capture-system-keys", "--no-pointer", "--provisioning-opts", "username=admin,password=secret,enablesRemoteLogin=true",
      ])
  }

  @Test func runCommandLineMasksProvisioningPassword() {
    var options = RunOptions(name: "vm")
    options.provisioning = .init(username: "me", password: "hunter2")
    let line = TartCommand.run(options).commandLine
    #expect(!line.contains("hunter2"))
    #expect(line.hasPrefix("tart run vm --provisioning-opts"))
  }

  @Test func runBridgedRepeatsFlagPerInterface() {
    let options = RunOptions(name: "vm", network: .bridged(interfaces: ["en0", "Wi-Fi"]))
    #expect(options.arguments == ["run", "vm", "--net-bridged", "en0", "--net-bridged", "Wi-Fi"])
  }

  @Test func runHeadlessAndHostOnly() {
    let options = RunOptions(name: "vm", display: .headless, network: .hostOnly, suspendable: true)
    #expect(options.arguments == ["run", "vm", "--no-graphics", "--net-host", "--suspendable"])
  }

  @Test func setPreservesDisplayRefit() {
    let options = SetOptions(name: "vm", cpuCount: 6, memoryMB: 8192, display: "1920x1080px", displayRefit: false)
    #expect(
      options.arguments == [
        "set", "vm", "--cpu", "6", "--memory", "8192", "--display", "1920x1080px", "--no-display-refit",
      ])
    #expect(SetOptions(name: "vm").hasChanges == false)
  }

  @Test func loginNeverPutsPasswordInArguments() {
    let options = LoginOptions(host: "ghcr.io", username: "octocat", insecure: true)
    #expect(options.arguments == ["login", "ghcr.io", "--username", "octocat", "--password-stdin", "--insecure"])
  }

  @Test func execPlacesFlagsBeforeName() {
    let options = ExecOptions(name: "vm", command: ["ls", "-la"], interactive: true)
    #expect(options.arguments == ["exec", "-i", "vm", "ls", "-la"])
  }

  @Test func pushWithLabelsAndChunks() {
    let options = PushOptions(
      localName: "vm", remoteNames: ["ghcr.io/me/vm:1", "ghcr.io/me/vm:latest"], chunkSizeMB: 3,
      labels: [.init(key: "org.opencontainers.image.source", value: "https://example.com"), .init(key: "", value: "x")],
      populateCache: true)
    #expect(
      options.arguments == [
        "push", "vm", "ghcr.io/me/vm:1", "ghcr.io/me/vm:latest", "--chunk-size", "3",
        "--label", "org.opencontainers.image.source=https://example.com", "--populate-cache",
      ])
  }

  @Test func pruneRequiresCriteria() {
    #expect(PruneOptions().hasCriteria == false)
    let options = PruneOptions(entries: .vms, olderThanDays: 7, spaceBudgetGB: 50, garbageCollect: true)
    #expect(options.hasCriteria)
    #expect(options.arguments == ["prune", "--entries", "vms", "--older-than", "7", "--space-budget", "50", "--gc"])
  }

  @Test func simpleCommands() {
    #expect(TartCommand.stop(name: "vm").arguments == ["stop", "vm"])
    #expect(TartCommand.stop(name: "vm", timeoutSeconds: 5).arguments == ["stop", "vm", "--timeout", "5"])
    #expect(TartCommand.delete(names: ["a", "b"]).arguments == ["delete", "a", "b"])
    #expect(TartCommand.export(name: "vm", path: "/tmp/vm.tvm").arguments == ["export", "vm", "/tmp/vm.tvm"])
    #expect(TartCommand.importVM(path: "/tmp/vm.tvm", name: "vm").arguments == ["import", "/tmp/vm.tvm", "vm"])
    #expect(TartCommand.get(name: "vm").arguments == ["get", "vm", "--format", "json"])
    #expect(TartCommand.list().arguments == ["list", "--format", "json"])
    #expect(TartCommand.ip(IPOptions(name: "vm", waitSeconds: 30, resolver: .agent)).arguments
      == ["ip", "vm", "--wait", "30", "--resolver", "agent"])
    #expect(TartCommand.version.arguments == ["--version"])
  }

  @Test func shellQuoting() {
    #expect(ShellQuoting.quote("simple-name_1.0") == "simple-name_1.0")
    #expect(ShellQuoting.quote("") == "''")
    #expect(ShellQuoting.quote("with space") == "'with space'")
    #expect(ShellQuoting.quote("it's") == "'it'\\''s'")
    #expect(TartCommand.rename(name: "a b", newName: "c").commandLine == "tart rename 'a b' c")
  }

  @Test func nameValidation() {
    #expect(VMNameValidation.problem(with: "dev-vm") == nil)
    #expect(VMNameValidation.problem(with: "") != nil)
    #expect(VMNameValidation.problem(with: "a/b") != nil)
    #expect(VMNameValidation.problem(with: "-x") != nil)
  }
}
