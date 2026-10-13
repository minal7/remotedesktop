#if DEBUG
import Foundation

@MainActor
enum DebugAgentEvalCommand {
    static let argument = "--debug-agent-eval"

    static func shouldRun(arguments: [String] = CommandLine.arguments) -> Bool {
        arguments.dropFirst().first == argument
    }

    static func runIfRequested(
        arguments: [String] = CommandLine.arguments,
        input: FileHandle = .standardInput,
        output: FileHandle = .standardOutput,
        errorOutput: FileHandle = .standardError
    ) async -> Int32? {
        guard shouldRun(arguments: arguments) else { return nil }
        guard Array(arguments.dropFirst()).count == 1 else {
            write("invalid evaluation command arguments\n", to: errorOutput)
            return 2
        }
        do {
            let data = input.readDataToEndOfFile()
            let request = try AgentEvalRequest.decodeStrict(data)
            let response = try await DebugAgentEvalSession(request: request).run()
            let encoded = try JSONEncoder().encode(response)
            output.write(encoded)
            output.write(Data([0x0A]))
            return 0
        } catch {
            write("evaluation driver failed: \(error.localizedDescription)\n", to: errorOutput)
            return 1
        }
    }

    private static func write(_ value: String, to handle: FileHandle) {
        handle.write(Data(value.utf8))
    }
}
#endif
