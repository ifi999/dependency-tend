import Darwin
import Foundation

public struct CommandOutput: Equatable, Sendable {
    public let stdout: String
    public let stderr: String
    public let exitCode: Int32
    public init(stdout: String, stderr: String, exitCode: Int32) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
    }
}

public enum CommandError: Error, Equatable {
    case timeout(String)       // 실행 파일 이름
    case launchFailed(String)  // 경로 + 원인
}

public protocol CommandRunning: Sendable {
    /// environment: ProcessInfo 환경 위에 머지되는 추가/오버라이드 변수.
    /// GUI 앱은 로그인 셸 PATH를 상속받지 않으므로(실측 함정) 호출자가 PATH를 명시할 수 있어야 한다.
    func run(_ executable: URL, arguments: [String],
             environment: [String: String], timeout: TimeInterval) async throws -> CommandOutput
}

public extension CommandRunning {
    func run(_ executable: URL, arguments: [String], timeout: TimeInterval) async throws -> CommandOutput {
        try await run(executable, arguments: arguments, environment: [:], timeout: timeout)
    }
}

public struct ProcessCommandRunner: CommandRunning {
    /// SIGTERM 후 이 시간 내에 안 죽으면 SIGKILL (terminate는 직접 자식에게만 전달된다)
    let killGracePeriod: TimeInterval
    /// 프로세스 종료 후 파이프 EOF를 기다리는 최대 시간 — 손자가 파이프를 쥐고 있어도 진행
    let pipeDrainTimeout: TimeInterval
    private let processTree: @Sendable (pid_t) -> [pid_t]
    private let processIdentity: @Sendable (pid_t) -> String?
    private let signaler: @Sendable (pid_t, Int32) -> Void

    public init(killGracePeriod: TimeInterval = 5, pipeDrainTimeout: TimeInterval = 5) {
        self.killGracePeriod = killGracePeriod
        self.pipeDrainTimeout = pipeDrainTimeout
        processTree = { rootPID in Self.descendantPIDs(of: rootPID) }
        processIdentity = { pid in Self.processStartTime(of: pid) }
        signaler = { pid, signal in Darwin.kill(pid, signal) }
    }

    init(killGracePeriod: TimeInterval,
         pipeDrainTimeout: TimeInterval,
         processTree: @escaping @Sendable (pid_t) -> [pid_t],
         processIdentity: @escaping @Sendable (pid_t) -> String? = { pid in Self.processStartTime(of: pid) },
         signaler: @escaping @Sendable (pid_t, Int32) -> Void) {
        self.killGracePeriod = killGracePeriod
        self.pipeDrainTimeout = pipeDrainTimeout
        self.processTree = processTree
        self.processIdentity = processIdentity
        self.signaler = signaler
    }

    public func run(_ executable: URL, arguments: [String],
                    environment: [String: String], timeout: TimeInterval) async throws -> CommandOutput {
        let runner = self
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try runner.runBlocking(executable, arguments,
                                                                          environment: environment,
                                                                          timeout: timeout))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func runBlocking(_ executable: URL, _ arguments: [String],
                             environment: [String: String], timeout: TimeInterval) throws -> CommandOutput {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if !environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment
                .merging(environment) { _, override in override }
        }
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        // 함정: readDataToEndOfFile은 손자 프로세스가 파이프 write end를 쥐고 있으면 영원히 블록.
        // readabilityHandler로 수집하고 drain 데드라인으로 어떤 경우에도 반환을 보장한다.
        let outCollector = PipeCollector(outPipe)
        let errCollector = PipeCollector(errPipe)

        do { try process.run() } catch {
            throw CommandError.launchFailed("\(executable.path): \(error.localizedDescription)")
        }

        let timedOut = AtomicFlag()
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler { [grace = killGracePeriod] in
            timedOut.set()
            let rootPID = process.processIdentifier
            let initialDescendants = processTree(rootPID)
            let initialIdentities = Self.identities(for: initialDescendants, using: processIdentity)
            Self.signalProcessTree(rootPID: rootPID, knownDescendants: initialDescendants,
                                   signal: SIGTERM, includeRoot: true, signaler: signaler)
            DispatchQueue.global().asyncAfter(deadline: .now() + grace) {
                let verifiedInitialDescendants = Self.verifiedPIDs(initialIdentities, using: processIdentity)
                let currentDescendants = process.isRunning ? processTree(rootPID) : []
                Self.signalProcessTree(rootPID: rootPID,
                                       knownDescendants: verifiedInitialDescendants + currentDescendants,
                                       signal: SIGKILL,
                                       includeRoot: process.isRunning,
                                       signaler: signaler)
            }
        }
        timer.resume()

        process.waitUntilExit()
        timer.cancel()

        let stdout = outCollector.finish(waitingUpTo: pipeDrainTimeout)
        let stderr = errCollector.finish(waitingUpTo: pipeDrainTimeout)

        if timedOut.isSet { throw CommandError.timeout(executable.lastPathComponent) }
        return CommandOutput(stdout: String(data: stdout, encoding: .utf8) ?? "",
                             stderr: String(data: stderr, encoding: .utf8) ?? "",
                             exitCode: process.terminationStatus)
    }

    private static func signalProcessTree(rootPID: pid_t, knownDescendants: [pid_t], signal: Int32,
                                          includeRoot: Bool,
                                          signaler: @Sendable (pid_t, Int32) -> Void) {
        let pids = Array(Set(knownDescendants)).filter { $0 > 0 && $0 != rootPID }
        for pid in pids {
            signaler(pid, signal)
        }
        if includeRoot {
            signaler(rootPID, signal)
        }
    }

    private struct ProcessIdentity: Equatable {
        let pid: pid_t
        let token: String
    }

    private static func identities(for pids: [pid_t],
                                   using identity: @Sendable (pid_t) -> String?) -> [ProcessIdentity] {
        pids.compactMap { pid in
            guard let token = identity(pid) else { return nil }
            return ProcessIdentity(pid: pid, token: token)
        }
    }

    private static func verifiedPIDs(_ identities: [ProcessIdentity],
                                     using identity: @Sendable (pid_t) -> String?) -> [pid_t] {
        identities.compactMap { known in
            identity(known.pid) == known.token ? known.pid : nil
        }
    }

    private static func descendantPIDs(of rootPID: pid_t) -> [pid_t] {
        let pairs = processParentPairs()
        var childrenByParent: [pid_t: [pid_t]] = [:]
        for pair in pairs {
            childrenByParent[pair.parent, default: []].append(pair.pid)
        }

        var result: [pid_t] = []
        var stack = childrenByParent[rootPID] ?? []
        while let pid = stack.popLast() {
            result.append(pid)
            stack.append(contentsOf: childrenByParent[pid] ?? [])
        }
        return result
    }

    private static func processParentPairs() -> [(pid: pid_t, parent: pid_t)] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,ppid="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return []
        }
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ")
            guard parts.count >= 2,
                  let pid = pid_t(parts[0]),
                  let parent = pid_t(parts[1]) else {
                return nil
            }
            return (pid: pid, parent: parent)
        }
    }

    private static func processStartTime(of pid: pid_t) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", "\(pid)", "-o", "lstart="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text?.isEmpty == false ? text : nil
    }
}

/// readabilityHandler 기반 파이프 수집기. EOF가 안 와도 finish의 데드라인 후 진행한다.
final class PipeCollector: @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()
    private var buffer = Data()
    private let eof = DispatchSemaphore(value: 0)

    init(_ pipe: Pipe) {
        handle = pipe.fileHandleForReading
        handle.readabilityHandler = { [weak self] h in
            let chunk = h.availableData
            if chunk.isEmpty { // EOF
                h.readabilityHandler = nil
                self?.eof.signal()
            } else if let self {
                self.lock.lock()
                self.buffer.append(chunk)
                self.lock.unlock()
            }
        }
    }

    /// EOF까지 최대 deadline 대기. 손자가 파이프를 쥐고 있어도 deadline 후 수집을 멈추고 반환.
    func finish(waitingUpTo seconds: TimeInterval) -> Data {
        _ = eof.wait(timeout: .now() + seconds)
        handle.readabilityHandler = nil
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }
}

/// 락으로 보호되는 단순 불리언 플래그
final class AtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}
