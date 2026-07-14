import AppKit
import Foundation

guard CommandLine.arguments.count == 2,
      let rawPID = Int32(CommandLine.arguments[1]),
      let application = NSRunningApplication(processIdentifier: rawPID) else {
    fputs("usage: MCPAcceptanceFrontmostRestorer PID\n", stderr)
    exit(2)
}

guard application.activate(options: []) else {
    fputs("could not activate prior application\n", stderr)
    exit(3)
}

let deadline = Date().addingTimeInterval(1)
while Date() < deadline {
    if application.isActive {
        exit(0)
    }
    RunLoop.current.run(until: Date().addingTimeInterval(0.02))
}
fputs("prior application did not become active\n", stderr)
exit(3)
