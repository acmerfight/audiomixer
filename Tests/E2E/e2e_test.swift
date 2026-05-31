import Foundation

/// End-to-end process-level tests.
/// These verify that the BINARY can start, produce output, and exit cleanly.
/// This is the test that would have caught the DispatchSemaphore deadlock.

nonisolated(unsafe) var passed = 0
nonisolated(unsafe) var failed = 0

func check(_ ok: Bool, _ msg: String) {
    if ok { passed += 1; print("  ✓ \(msg)") }
    else { failed += 1; print("  ✗ \(msg)") }
}

/// Runs the binary with given args, kills after timeout, returns (stdout+stderr, exitCode, timedOut)
func runBinary(args: [String] = [], timeoutSeconds: Double = 10) -> (output: String, exitCode: Int32, timedOut: Bool) {
    let binaryPath = ProcessInfo.processInfo.arguments[0]
        .components(separatedBy: "/").dropLast().joined(separator: "/") + "/AudioRecorder"

    // Fallback: search relative to working directory
    let candidates = [
        binaryPath,
        ".build/release/AudioRecorder",
        ".build/debug/AudioRecorder",
    ]

    guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
        return ("ERROR: AudioRecorder binary not found at \(candidates)", 127, false)
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = args

    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe

    do {
        try process.run()
    } catch {
        return ("Failed to launch: \(error)", 127, false)
    }

    // Timeout watchdog
    var timedOut = false
    let timer = DispatchSource.makeTimerSource(queue: .global())
    timer.schedule(deadline: .now() + timeoutSeconds)
    timer.setEventHandler {
        timedOut = true
        process.terminate()
    }
    timer.resume()

    process.waitUntilExit()
    timer.cancel()

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let output = String(data: data, encoding: .utf8) ?? ""

    return (output, process.terminationStatus, timedOut)
}

// ═══════════════════════════════════════════════════════════════

print("═══ E2E: Process Lifecycle Tests ═══\n")

// Test 1: Binary starts and produces output within 5 seconds
do {
    print("  Running: AudioRecorder --duration 3 (timeout 8s)...")
    let result = runBinary(args: ["--duration", "3"], timeoutSeconds: 8)

    check(!result.timedOut, "Process did not hang (completed within timeout)")

    if result.timedOut {
        print("    CRITICAL: Process hung — this is the deadlock bug")
        print("    Output before hang: \(result.output.prefix(200))")
    } else {
        check(result.output.contains("Checking permissions"), "Prints permission check message")

        let hasPermissionError = result.output.contains("Screen Recording permission not granted")
        let hasRecording = result.output.contains("Recording to:")

        if hasPermissionError {
            check(true, "Correctly reports missing permission (expected in CI/sandboxed env)")
            check(result.exitCode == 1, "Exits with code 1 on permission error")
        } else if hasRecording {
            check(true, "Started recording successfully")
            check(result.output.contains("Saved:"), "Completed and saved file")
            check(result.exitCode == 0, "Exits with code 0 on success")

            // Verify output file exists and is valid
            if let savedLine = result.output.components(separatedBy: "\n")
                .first(where: { $0.contains("Saved:") }) {
                let path = savedLine.replacingOccurrences(of: "Saved: ", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
                let fileExists = FileManager.default.fileExists(atPath: path)
                check(fileExists, "Output WAV file exists at \(path)")

                if fileExists {
                    let attrs = try? FileManager.default.attributesOfItem(atPath: path)
                    let size = attrs?[.size] as? Int ?? 0
                    check(size > 44, "WAV file has content beyond header (size: \(size) bytes)")

                    // Cleanup
                    try? FileManager.default.removeItem(atPath: path)
                }
            }
        } else {
            check(false, "Unexpected output: \(result.output.prefix(300))")
        }
    }
}

// Test 2: Binary with invalid args still starts (no crash)
do {
    print("\n  Running: AudioRecorder --duration abc (timeout 5s)...")
    let result = runBinary(args: ["--duration", "abc"], timeoutSeconds: 5)

    // --duration abc should be ignored (parseDuration returns nil), so it runs indefinitely
    // We expect it to start (print "Checking permissions") and then we kill it via timeout
    let started = result.output.contains("Checking permissions")
    check(started || result.timedOut, "Process starts even with invalid duration arg")
}

// ═══════════════════════════════════════════════════════════════

print("\n" + String(repeating: "═", count: 50))
print("E2E: \(passed) passed, \(failed) failed")
if failed > 0 { print("FAILED"); exit(1) }
else { print("ALL E2E TESTS PASSED ✓"); exit(0) }
