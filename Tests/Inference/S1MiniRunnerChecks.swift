import Darwin
import Foundation

@main
struct S1MiniRunnerChecks {
    @MainActor
    static func main() async throws {
        func require(_ condition: Bool, _ message: String = "Check failed") {
            precondition(condition, message)
        }
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let helper = root.appendingPathComponent("fake-helper")
        let model = root.appendingPathComponent("model.gguf")
        try Data("model".utf8).write(to: model)
        // Hosted Macs need time for cold Python startup. The hanging fixtures sleep for 10 seconds,
        // so this deadline still verifies timeout and forced termination without racing startup.
        let runner = S1MiniRunner(
            helperURL: helper, timeout: .seconds(3),
            jobRootURL: root.appendingPathComponent("jobs"), idleTimeout: .seconds(30)
        )
        let mode = DictationMode.initial[0]
        func clean(_ text: String) async throws -> String {
            do {
                return try await runner.clean(text: text, modelURL: model, mode: mode)
            } catch {
                FileHandle.standardError.write(
                    Data("[DEBUG-ci-helper] Request \(text.prefix(32)): \(error)\n".utf8))
                throw error
            }
        }
        let first = try await clean("first")
        let pid = first.split(separator: ":")[0]
        let second = try await clean("second")
        require(second == "\(pid):second", "Successive requests must reuse the process")
        let chunks = try await clean(String(repeating: "word ", count: 700))
        require(chunks.components(separatedBy: "\(pid):").count > 2, "Chunks must reuse one process")
        try Data("changed model".utf8).write(to: model, options: .atomic)
        let replacement = try await clean("replacement")
        require(replacement.split(separator: ":")[0] != pid, "Replacement must evict the old model")
        for invalid in ["wrong-id", "malformed", "crash", "stdout-eof", "oversized", "duplicate"] {
            do {
                _ = try await clean(invalid)
                preconditionFailure("Invalid helper response succeeded: \(invalid)")
            } catch {}
            require(try await clean("recovered").hasSuffix(":recovered"))
        }
        do {
            _ = try await clean("hang")
            preconditionFailure("Timeout did not interrupt inference")
        } catch {
            require(error.localizedDescription.contains("deadline"))
        }
        require(try await clean("after-timeout").hasSuffix(":after-timeout"))
        do {
            _ = try await clean("ignore-term")
            preconditionFailure("A child ignoring SIGTERM must still time out")
        } catch { require(error.localizedDescription.contains("deadline")) }
        _ = try await clean("close-input")
        try await Task.sleep(for: .milliseconds(50))
        do {
            _ = try await clean("broken-pipe")
            preconditionFailure("A closed input pipe must fail safely")
        } catch {}
        require(try await clean("after-broken-pipe").hasSuffix(":after-broken-pipe"))
        let active = Task { try await clean("hang") }
        try await Task.sleep(for: .milliseconds(50))
        active.cancel()
        do {
            _ = try await active.value
            preconditionFailure("Task cancellation succeeded")
        } catch is CancellationError {} catch { throw error }
        require(try await clean("after-cancel").hasSuffix(":after-cancel"))
        let unloading = Task { try await clean("hang") }
        try await Task.sleep(for: .milliseconds(50))
        await runner.unload()
        do {
            _ = try await unloading.value
            preconditionFailure("Unload must cancel pending cleanup")
        } catch is CancellationError {} catch { throw error }
        let underPressure = Task { try await clean("slow") }
        try await Task.sleep(for: .milliseconds(50))
        runner.releaseForMemoryPressure()
        let pressureResult = try await underPressure.value
        require(pressureResult.hasSuffix(":slow"), "Memory pressure must preserve active cleanup")
        let afterPressure = try await clean("after-pressure")
        require(afterPressure.split(separator: ":")[0] != pressureResult.split(separator: ":")[0])
        runner.releaseForMemoryPressure()
        let afterIdlePressure = try await clean("idle-pressure")
        require(afterIdlePressure.split(separator: ":")[0] != afterPressure.split(separator: ":")[0])
        let last = try await clean("last")
        let lastPID = Int32(last.split(separator: ":")[0])!
        await runner.unload()
        require(kill(lastPID, 0) == -1 && errno == ESRCH, "Unload returned before process exit")
        require(
            (try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("jobs").path))
                .isEmpty)
        let idle = S1MiniRunner(
            helperURL: helper, jobRootURL: root.appendingPathComponent("idle-jobs"),
            idleTimeout: .milliseconds(20)
        )
        let beforeIdle = try await idle.clean(text: "idle", modelURL: model, mode: mode)
        try await Task.sleep(for: .milliseconds(150))
        let afterIdle = try await idle.clean(text: "idle", modelURL: model, mode: mode)
        require(beforeIdle != afterIdle, "Idle expiry must release the process")
        await idle.unload()
        func transientRunnerPID() async throws -> Int32 {
            let transient = S1MiniRunner(
                helperURL: helper, jobRootURL: root.appendingPathComponent("transient"))
            let result = try await transient.clean(text: "transient", modelURL: model, mode: mode)
            return Int32(result.split(separator: ":")[0])!
        }
        let transientPID = try await transientRunnerPID()
        try await Task.sleep(for: .milliseconds(100))
        require(kill(transientPID, 0) == -1 && errno == ESRCH, "Destroying the runner must release its child")
        print(
            "S1-mini runner checks passed: reuse, chunks, replacement, protocol errors, crash/EOF, timeout, cancellation, unload, and idle expiry."
        )
    }
}
