import Foundation

/// Runs the bundled llama-server for one model and talks to it over loopback.
/// Starts lazily, restarts after a crash, and frees its memory when idle, so the
/// agent costs nothing on a 16 GB Mac while it isn't working.
public final class LlamaServer: ModelClient, @unchecked Sendable {
    public struct Configuration: Sendable {
        public var serverBinary: URL
        public var modelFile: URL
        public var projectorFile: URL?
        public var contextTokens = 8_192
        public var gpuLayers = 99
        public var threads: Int?
        public var extraArguments: [String] = []
        /// Sent through the chat template; used to turn off "thinking" on models that have it.
        public var templateOptions: [String: Bool] = ["enable_thinking": false]
        public var idleShutdown: TimeInterval = 600
        /// Records the server's process so a crashed host can't leave 6 GB behind.
        public var pidFile: URL?

        public init(serverBinary: URL, modelFile: URL, projectorFile: URL?, contextTokens: Int = 8_192) {
            self.serverBinary = serverBinary; self.modelFile = modelFile
            self.projectorFile = projectorFile; self.contextTokens = contextTokens
        }
    }

    public let configuration: Configuration
    private let lock = NSLock()
    private var process: Process?
    private var port: Int = 0
    private let apiKey = UUID().uuidString
    private var inFlight: URLSessionDataTask?
    private var idleTimer: DispatchSourceTimer?
    private var starting: Task<Void, Error>?
    private var logTail = LogTail()

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 600
        config.connectionProxyDictionary = [:]
        return URLSession(configuration: config)
    }()

    public init(configuration: Configuration) { self.configuration = configuration }

    deinit { stop() }

    // MARK: Lifecycle

    public func start() async throws {
        let existing: Task<Void, Error> = lock.withLock {
            if let starting { return starting }
            if process?.isRunning == true { return Task {} }
            let task = Task { try await self.launch() }
            starting = task
            return task
        }
        defer { lock.withLock { starting = nil } }
        try await existing.value
    }

    public func stop() {
        lock.withLock {
            inFlight?.cancel()
            idleTimer?.cancel(); idleTimer = nil
            if let process, process.isRunning {
                process.terminate()
                let pid = process.processIdentifier
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) { kill(pid, SIGKILL) }
            }
            process = nil
        }
    }

    private func launch() async throws {
        guard FileManager.default.isExecutableFile(atPath: configuration.serverBinary.path) else {
            throw ModelError.startupFailed("runtime not found at \(configuration.serverBinary.path)")
        }
        guard FileManager.default.fileExists(atPath: configuration.modelFile.path) else {
            throw ModelError.startupFailed("model not found at \(configuration.modelFile.path)")
        }
        let chosenPort = Self.freePort()
        // A file keeps the key out of the process list.
        let keyFile = FileManager.default.temporaryDirectory.appendingPathComponent("local-agent-\(UUID().uuidString).key")
        FileManager.default.createFile(atPath: keyFile.path, contents: Data(apiKey.utf8), attributes: [.posixPermissions: 0o600])
        defer { try? FileManager.default.removeItem(at: keyFile) }
        var arguments = [
            "--model", configuration.modelFile.path,
            "--host", "127.0.0.1", "--port", String(chosenPort), "--api-key-file", keyFile.path,
            "--ctx-size", String(configuration.contextTokens), "--parallel", "1",
            "--n-gpu-layers", String(configuration.gpuLayers),
            "--no-webui", "--jinja", "--no-context-shift",
            // Keep reusing the shared prompt prefix; it is the main latency saver.
            "--cache-reuse", "64",
            // The defaults keep up to 8 GB of old prompts and 32 snapshots of each. There is only
            // one conversation and the slot already holds it; that memory is needed on a 16 GB Mac.
            "--cache-ram", "0", "--ctx-checkpoints", "2",
        ]
        if let projector = configuration.projectorFile { arguments += ["--mmproj", projector.path] }
        if let threads = configuration.threads { arguments += ["--threads", String(threads)] }
        arguments += configuration.extraArguments

        let child = Process()
        child.executableURL = configuration.serverBinary
        child.arguments = arguments
        child.currentDirectoryURL = configuration.serverBinary.deletingLastPathComponent()
        var environment = ProcessInfo.processInfo.environment
        environment["DYLD_LIBRARY_PATH"] = configuration.serverBinary.deletingLastPathComponent().path
        child.environment = environment
        let pipe = Pipe()
        child.standardOutput = pipe
        child.standardError = pipe
        let tail = logTail
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { tail.append(data) }
        }
        do { try child.run() } catch { throw ModelError.startupFailed(String(describing: error)) }
        lock.withLock { process = child; port = chosenPort }
        if let pidFile = configuration.pidFile {
            try? String(child.processIdentifier).write(to: pidFile, atomically: true, encoding: .utf8)
        }

        // A cold 5 GB model takes a while to map; give up only after a long wait.
        let deadline = Date().addingTimeInterval(240)
        while Date() < deadline {
            try Task.checkCancellation()
            guard child.isRunning else { throw ModelError.startupFailed(tail.text) }
            if await isHealthy() { return }
            try await Task.sleep(for: .milliseconds(300))
        }
        stop()
        throw ModelError.startupFailed("timed out loading the model. \(tail.text)")
    }

    private func isHealthy() async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/health") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        guard let (_, response) = try? await session.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    /// If an earlier host died without stopping its server, end that server now.
    /// Only ever signals a process that really is this runtime binary.
    public func reapStaleServer() {
        guard let pidFile = configuration.pidFile,
              let text = try? String(contentsOf: pidFile, encoding: .utf8), let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        if proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0,
           String(cString: buffer) == configuration.serverBinary.resolvingSymlinksInPath().path {
            kill(pid, SIGTERM)
        }
        try? FileManager.default.removeItem(at: pidFile)
    }

    public var isRunning: Bool { lock.withLock { process?.isRunning == true } }

    /// Peak memory matters on 16 GB; reported into traces.
    public var residentBytes: UInt64? {
        guard let pid = lock.withLock({ process?.processIdentifier }) else { return nil }
        var info = rusage_info_current()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, $0) }
        }
        return result == 0 ? info.ri_phys_footprint : nil
    }

    /// The most memory the server has used since it started.
    public var peakBytes: UInt64? {
        guard let pid = lock.withLock({ process?.processIdentifier }) else { return nil }
        var info = rusage_info_current()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, $0) }
        }
        return result == 0 ? info.ri_lifetime_max_phys_footprint : nil
    }

    private func scheduleIdleShutdown() {
        lock.withLock {
            idleTimer?.cancel()
            let timer = DispatchSource.makeTimerSource(queue: .global())
            timer.schedule(deadline: .now() + configuration.idleShutdown)
            timer.setEventHandler { [weak self] in self?.stop() }
            timer.resume()
            idleTimer = timer
        }
    }

    // MARK: Inference

    public func complete(_ request: ModelRequest) async throws -> ModelReply {
        try await start()
        lock.withLock { idleTimer?.cancel(); idleTimer = nil }
        defer { scheduleIdleShutdown() }

        let started = Date()
        var body: [String: Any] = [
            "messages": request.messages.map(Self.encode),
            "max_tokens": request.maxTokens,
            "temperature": request.temperature,
            "cache_prompt": true,
            "stream": false,
        ]
        if !configuration.templateOptions.isEmpty { body["chat_template_kwargs"] = configuration.templateOptions }
        if let schema = request.schema, let object = try? JSONSerialization.jsonObject(with: Data(schema.utf8)) {
            body["response_format"] = ["type": "json_schema", "json_schema": ["name": "action", "strict": true, "schema": object]]
        }
        let payload = try JSONSerialization.data(withJSONObject: body)
        guard let url = URL(string: "http://127.0.0.1:\(lock.withLock { port })/v1/chat/completions") else { throw ModelError.notRunning }
        var http = URLRequest(url: url)
        http.httpMethod = "POST"
        http.httpBody = payload
        http.timeoutInterval = request.timeout
        http.setValue("application/json", forHTTPHeaderField: "Content-Type")
        http.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await send(http, timeout: request.timeout)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let message = String(decoding: data, as: UTF8.self)
            if message.contains("exceed") && message.contains("context") { throw ModelError.contextOverflow }
            throw ModelError.http(status, message)
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = root["choices"] as? [[String: Any]], let message = choices.first?["message"] as? [String: Any],
              let text = message["content"] as? String else {
            throw ModelError.badResponse(String(decoding: data, as: UTF8.self))
        }
        let usage = root["usage"] as? [String: Any]
        let details = usage?["prompt_tokens_details"] as? [String: Any]
        let timings = root["timings"] as? [String: Any]
        return ModelReply(text: text,
                          promptTokens: usage?["prompt_tokens"] as? Int ?? 0,
                          cachedTokens: details?["cached_tokens"] as? Int ?? (timings?["cache_n"] as? Int ?? 0),
                          outputTokens: usage?["completion_tokens"] as? Int ?? 0,
                          seconds: Date().timeIntervalSince(started))
    }

    private func send(_ request: URLRequest, timeout: TimeInterval) async throws -> (Data, URLResponse) {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Data, URLResponse), Error>) in
                let task = session.dataTask(with: request) { data, response, error in
                    if let error = error as? URLError {
                        switch error.code {
                        case .timedOut: continuation.resume(throwing: ModelError.timeout)
                        case .cancelled: continuation.resume(throwing: CancellationError())
                        default: continuation.resume(throwing: ModelError.notRunning)
                        }
                    } else if let error {
                        continuation.resume(throwing: error)
                    } else if let data, let response {
                        continuation.resume(returning: (data, response))
                    } else {
                        continuation.resume(throwing: ModelError.notRunning)
                    }
                }
                lock.withLock { inFlight = task }
                task.resume()
            }
        } onCancel: { [weak self] in
            self?.cancelInFlight()
        }
    }

    /// Stop must be quick. Dropping the connection makes llama-server abandon generation.
    public func cancelInFlight() {
        lock.withLock { inFlight?.cancel(); inFlight = nil }
    }

    public func countTokens(_ text: String) async -> Int? {
        guard isRunning, let url = URL(string: "http://127.0.0.1:\(lock.withLock { port })/tokenize") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["content": text])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        guard let (data, _) = try? await session.data(for: request),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = root["tokens"] as? [Any] else { return nil }
        return tokens.count
    }

    private static func encode(_ message: ModelMessage) -> [String: Any] {
        guard let image = message.imageJPEG else { return ["role": message.role.rawValue, "content": message.text] }
        return ["role": message.role.rawValue, "content": [
            ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64," + image.base64EncodedString()]],
            ["type": "text", "text": message.text],
        ] as [[String: Any]]]
    }

    private static func freePort() -> Int {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(socketFD) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socketFD, $0, length) }
        }
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socketFD, $0, &length) }
        }
        return Int(UInt16(bigEndian: address.sin_port))
    }

    /// The last few KB of server output, for startup-failure messages.
    final class LogTail: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = Data()

        func append(_ data: Data) {
            lock.withLock {
                buffer.append(data)
                if buffer.count > 8_192 { buffer.removeFirst(buffer.count - 8_192) }
            }
        }

        var text: String { lock.withLock { String(decoding: buffer.suffix(1_500), as: UTF8.self) } }
    }
}
