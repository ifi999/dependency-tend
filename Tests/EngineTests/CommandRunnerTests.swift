import Darwin
import XCTest
@testable import Engine

final class CommandRunnerTests: XCTestCase {
    let runner = ProcessCommandRunner()

    func testCapturesStdoutAndExitZero() async throws {
        let out = try await runner.run(URL(fileURLWithPath: "/bin/echo"), arguments: ["hello"], timeout: 10)
        XCTAssertEqual(out.stdout, "hello\n")
        XCTAssertEqual(out.exitCode, 0)
    }

    func testCapturesNonZeroExit() async throws {
        let out = try await runner.run(URL(fileURLWithPath: "/usr/bin/false"), arguments: [], timeout: 10)
        XCTAssertEqual(out.exitCode, 1)
    }

    func testCapturesStderr() async throws {
        let out = try await runner.run(URL(fileURLWithPath: "/bin/sh"),
                                       arguments: ["-c", "echo oops 1>&2; exit 3"], timeout: 10)
        XCTAssertEqual(out.stderr, "oops\n")
        XCTAssertEqual(out.exitCode, 3)
    }

    func testEnvironmentIsMergedOverProcessInfo() async throws {
        // 실측 함정 대응: 호출자가 준 환경 변수가 ProcessInfo 환경 위에 머지되어야 한다
        let out = try await runner.run(URL(fileURLWithPath: "/bin/sh"),
                                       arguments: ["-c", "printf '%s' \"$TEND_TEST_VAR\""],
                                       environment: ["TEND_TEST_VAR": "injected"], timeout: 10)
        XCTAssertEqual(out.stdout, "injected")
    }

    func testTimeoutThrows() async {
        do {
            _ = try await runner.run(URL(fileURLWithPath: "/bin/sleep"), arguments: ["5"], timeout: 0.5)
            XCTFail("timeout이어야 함")
        } catch let e as CommandError {
            guard case .timeout = e else { return XCTFail("timeout 에러여야 함: \(e)") }
        } catch {
            XCTFail("CommandError여야 함: \(error)")
        }
    }

    func testLaunchFailureThrows() async {
        do {
            _ = try await runner.run(URL(fileURLWithPath: "/no/such/binary"), arguments: [], timeout: 5)
            XCTFail("launch 실패여야 함")
        } catch let e as CommandError {
            guard case .launchFailed = e else { return XCTFail("launchFailed여야 함: \(e)") }
        } catch {
            XCTFail("CommandError여야 함: \(error)")
        }
    }

    func testGrandchildHoldingPipeDoesNotHang() async {
        // 함정(재검토 발견): SIGTERM은 직접 자식에게만 간다. 파이프 write end를 상속한 손자가
        // 살아 있으면 read-to-EOF 방식은 영원히 블록된다 — drain 데드라인으로 반환을 보장해야 한다.
        let fast = ProcessCommandRunner(killGracePeriod: 0.5, pipeDrainTimeout: 0.3)
        let start = Date()
        do {
            _ = try await fast.run(URL(fileURLWithPath: "/bin/sh"),
                                   arguments: ["-c", "sleep 30 & exec /bin/sleep 30"], timeout: 0.5)
            XCTFail("timeout이어야 함")
        } catch let e as CommandError {
            guard case .timeout = e else { return XCTFail("timeout이어야 함: \(e)") }
        } catch {
            XCTFail("CommandError여야 함: \(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 5, "행 없이 수 초 내에 반환되어야 한다")
    }

    func testTimeoutTerminatesDescendantProcesses() async throws {
        let marker = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dependency-tend-child-\(UUID().uuidString).pid")
        let fast = ProcessCommandRunner(killGracePeriod: 0.2, pipeDrainTimeout: 0.2)
        let script = """
        import os, signal, sys, time
        pid = os.fork()
        if pid == 0:
            with open(sys.argv[1], "w") as f:
                f.write(str(os.getpid()))
                f.flush()
            os.setsid()
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            time.sleep(30)
        else:
            while not os.path.exists(sys.argv[1]):
                time.sleep(0.01)
            time.sleep(30)
        """

        do {
            _ = try await fast.run(URL(fileURLWithPath: "/usr/bin/python3"),
                                   arguments: ["-c", script, marker.path],
                                   timeout: 1.0)
            XCTFail("timeout이어야 함")
        } catch let e as CommandError {
            guard case .timeout = e else { return XCTFail("timeout이어야 함: \(e)") }
        } catch {
            XCTFail("CommandError여야 함: \(error)")
        }

        let pidText = try String(contentsOf: marker).trimmingCharacters(in: .whitespacesAndNewlines)
        let pid = pid_t(pidText) ?? 0
        defer {
            if pid > 0 { kill(pid, SIGKILL) }
            try? FileManager.default.removeItem(at: marker)
        }

        XCTAssertGreaterThan(pid, 0)
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            errno = 0
            if kill(pid, 0) != 0, errno == ESRCH {
                return
            }
            usleep(50_000)
        }
        XCTFail("timeout 이후 하위 프로세스가 남아 있습니다: pid \(pid)")
    }

    func testTimeoutDoesNotEscalateRootAfterItExitedFromTerm() async throws {
        let recorder = SignalRecorder()
        let fast = ProcessCommandRunner(
            killGracePeriod: 0.2,
            pipeDrainTimeout: 0.2,
            processTree: { _ in [] },
            signaler: { pid, signal in
                recorder.record(pid: pid, signal: signal)
                Darwin.kill(pid, signal)
            })

        let script = """
        import signal, sys, time
        signal.signal(signal.SIGTERM, lambda signum, frame: sys.exit(0))
        time.sleep(30)
        """

        do {
            _ = try await fast.run(URL(fileURLWithPath: "/usr/bin/python3"),
                                   arguments: ["-c", script],
                                   timeout: 0.2)
            XCTFail("timeout이어야 함")
        } catch let e as CommandError {
            guard case .timeout = e else { return XCTFail("timeout이어야 함: \(e)") }
        } catch {
            XCTFail("CommandError여야 함: \(error)")
        }

        let sentKill = await recorder.waitUntil(timeout: 0.5) { $0.signal == SIGKILL }
        XCTAssertFalse(sentKill,
                       "SIGTERM으로 종료된 루트 PID에 grace period 이후 SIGKILL을 보내면 안 됩니다")
    }

    func testTimeoutDoesNotKillDescendantPIDWhenIdentityChangedBeforeGraceKill() async throws {
        let reusedPID = pid_t(424_242)
        let recorder = SignalRecorder()
        let identities = ProcessIdentityStub(pid: reusedPID, tokens: ["original", "reused"])
        let fast = ProcessCommandRunner(
            killGracePeriod: 0.2,
            pipeDrainTimeout: 0.2,
            processTree: { _ in [reusedPID] },
            processIdentity: { identities.identity(for: $0) },
            signaler: { pid, signal in
                recorder.record(pid: pid, signal: signal)
                if pid != reusedPID {
                    Darwin.kill(pid, signal)
                }
            })

        do {
            _ = try await fast.run(URL(fileURLWithPath: "/bin/sleep"),
                                   arguments: ["30"],
                                   timeout: 0.2)
            XCTFail("timeout이어야 함")
        } catch let e as CommandError {
            guard case .timeout = e else { return XCTFail("timeout이어야 함: \(e)") }
        } catch {
            XCTFail("CommandError여야 함: \(error)")
        }

        let sentTerm = await recorder.waitUntil(timeout: 0.5) { $0.pid == reusedPID && $0.signal == SIGTERM }
        let sentKill = await recorder.waitUntil(timeout: 0.5) { $0.pid == reusedPID && $0.signal == SIGKILL }
        XCTAssertTrue(sentTerm)
        XCTAssertFalse(sentKill,
                       "PID identity가 바뀐 하위 프로세스에는 SIGKILL을 보내면 안 됩니다")
    }
}

private struct RecordedSignal: Equatable {
    let pid: pid_t
    let signal: Int32
}

private final class SignalRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var signals: [RecordedSignal] = []

    func record(pid: pid_t, signal: Int32) {
        lock.lock()
        defer { lock.unlock() }
        signals.append(RecordedSignal(pid: pid, signal: signal))
    }

    func contains(where predicate: (RecordedSignal) -> Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return signals.contains(where: predicate)
    }

    func waitUntil(
        timeout: TimeInterval = 1,
        pollIntervalNanoseconds: UInt64 = 20_000_000,
        matching predicate: @escaping (RecordedSignal) -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if contains(where: predicate) { return true }
            try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }
        return contains(where: predicate)
    }
}

private final class ProcessIdentityStub: @unchecked Sendable {
    private let pid: pid_t
    private let tokens: [String]
    private let lock = NSLock()
    private var index = 0

    init(pid: pid_t, tokens: [String]) {
        self.pid = pid
        self.tokens = tokens
    }

    func identity(for pid: pid_t) -> String? {
        guard pid == self.pid else { return "root" }
        lock.lock()
        defer { lock.unlock() }
        let token = tokens[min(index, tokens.count - 1)]
        index += 1
        return token
    }
}
