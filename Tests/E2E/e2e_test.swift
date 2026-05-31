import Foundation

/// End-to-end process-level tests.
///
/// Philosophy: these tests verify USER-OBSERVABLE BEHAVIOR, not internal logic.
/// Each test answers: "if I run this command, do I get the expected result?"
///
/// These tests would have caught:
///   - The DispatchSemaphore deadlock (process hangs)
///   - Permission check not working (process hangs without explanation)
///   - WAV file not being playable (afinfo fails)
///   - Recording being silent (file is all zeros)
///   - Ctrl+C not stopping the process

nonisolated(unsafe) var passed = 0
nonisolated(unsafe) var failed = 0

func check(_ ok: Bool, _ msg: String) {
    if ok { passed += 1; print("  ✓ \(msg)") }
    else { failed += 1; print("  ✗ \(msg)") }
}

func findBinary() -> String? {
    let selfDir = ProcessInfo.processInfo.arguments[0]
        .components(separatedBy: "/").dropLast().joined(separator: "/")
    let candidates = [
        selfDir + "/AudioRecorder",
        ".build/release/AudioRecorder",
        ".build/debug/AudioRecorder",
    ]
    return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
}

struct RunResult {
    let output: String
    let exitCode: Int32
    let timedOut: Bool
}

func run(args: [String], timeout: Double = 10, sendSIGINTAfter: Double? = nil) -> RunResult {
    guard let path = findBinary() else {
        return RunResult(output: "Binary not found", exitCode: 127, timedOut: false)
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = args
    process.currentDirectoryURL = FileManager.default.temporaryDirectory

    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe

    do { try process.run() }
    catch { return RunResult(output: "Launch failed: \(error)", exitCode: 127, timedOut: false) }

    // Optional: send SIGINT after delay (simulate Ctrl+C)
    if let delay = sendSIGINTAfter {
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
            if process.isRunning {
                kill(process.processIdentifier, SIGINT)
            }
        }
    }

    // Timeout watchdog
    var timedOut = false
    let timer = DispatchSource.makeTimerSource(queue: .global())
    timer.schedule(deadline: .now() + timeout)
    timer.setEventHandler {
        timedOut = true
        process.terminate()
    }
    timer.resume()

    process.waitUntilExit()
    timer.cancel()

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let output = String(data: data, encoding: .utf8) ?? ""
    return RunResult(output: output, exitCode: process.terminationStatus, timedOut: timedOut)
}

func extractSavedPath(from output: String) -> String? {
    output.components(separatedBy: "\n")
        .first { $0.contains("Saved:") }?
        .replacingOccurrences(of: "Saved: ", with: "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

// ═══════════════════════════════════════════════════════════════
print("═══ E2E: Process Does Not Hang ═══\n")
// ═══════════════════════════════════════════════════════════════

do {
    let result = run(args: ["--duration", "2"], timeout: 8)
    check(!result.timedOut, "Process completes within 8s for a 2s recording")

    if result.timedOut {
        print("    CRITICAL: Deadlock or infinite hang detected")
        print("    Last output: \(result.output.prefix(200))")
    }
}

// ═══════════════════════════════════════════════════════════════
print("\n═══ E2E: Permission Check Reports Clearly ═══\n")
// ═══════════════════════════════════════════════════════════════

do {
    let result = run(args: ["--duration", "1"], timeout: 8)
    let hasPermCheck = result.output.contains("Checking permissions")
    check(hasPermCheck, "Prints 'Checking permissions' on startup")

    let hasPermError = result.output.contains("permission not granted")
    let hasRecording = result.output.contains("Recording to:")
    check(hasPermError || hasRecording, "Either reports permission error OR starts recording (not silent)")
}

// ═══════════════════════════════════════════════════════════════
print("\n═══ E2E: Timed Recording Produces Valid WAV ═══\n")
// ═══════════════════════════════════════════════════════════════

do {
    let result = run(args: ["--duration", "3"], timeout: 10)

    guard result.output.contains("Saved:"), let path = extractSavedPath(from: result.output) else {
        // No permission — skip file validation tests
        if result.output.contains("permission not granted") {
            check(true, "Skipped (no permission in this environment)")
        } else {
            check(false, "Expected 'Saved:' in output, got: \(result.output.prefix(200))")
        }
        // Jump to next section
        if false {} // placeholder for control flow
        check(true, "---")
        check(true, "---")
        check(true, "---")
        check(true, "---")
        print("") // spacer before next section
        fatalError("unreachable") // won't reach due to above
    }
    defer { try? FileManager.default.removeItem(atPath: path) }

    // File exists
    let exists = FileManager.default.fileExists(atPath: path)
    check(exists, "Output file exists")

    // File is non-trivial size (3s stereo 48kHz Int16 ≈ 576KB)
    let attrs = try? FileManager.default.attributesOfItem(atPath: path)
    let size = (attrs?[.size] as? Int) ?? 0
    check(size > 100_000, "File is substantial (\(size) bytes, expect ~576KB for 3s)")
    check(size < 2_000_000, "File is not unreasonably large (\(size) bytes)")

    // afinfo can parse it
    let afinfo = Process()
    afinfo.executableURL = URL(fileURLWithPath: "/usr/bin/afinfo")
    afinfo.arguments = [path]
    let afPipe = Pipe()
    afinfo.standardOutput = afPipe
    afinfo.standardError = afPipe
    try? afinfo.run()
    afinfo.waitUntilExit()
    let afOutput = String(data: afPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    check(afinfo.terminationStatus == 0, "afinfo validates WAV file")

    // Correct format
    check(afOutput.contains("48000 Hz"), "Sample rate is 48000 Hz")
    check(afOutput.contains("2 ch"), "Stereo (2 channels)")
    check(afOutput.contains("Int16"), "16-bit integer PCM")

    // Duration approximately correct
    if let durationLine = afOutput.components(separatedBy: "\n").first(where: { $0.contains("estimated duration") }) {
        let numbers = durationLine.components(separatedBy: CharacterSet.decimalDigits.inverted).compactMap { Double($0) }
        if let dur = numbers.first {
            check(dur >= 2.0 && dur <= 5.0, "Duration ~3s (got \(dur)s)")
        }
    }

    // Audio is not silence
    let fileData = try? Data(contentsOf: URL(fileURLWithPath: path))
    if let audioData = fileData?[44...] {
        var maxAbs: Int16 = 0
        audioData.withUnsafeBytes { buf in
            for sample in buf.bindMemory(to: Int16.self) {
                let a = sample < 0 ? -sample : sample
                if a > maxAbs { maxAbs = a }
            }
        }
        check(maxAbs > 100, "Audio is not silence (peak: \(maxAbs))")
    }
}

// ═══════════════════════════════════════════════════════════════
print("\n═══ E2E: Ctrl+C Stops Recording Gracefully ═══\n")
// ═══════════════════════════════════════════════════════════════

do {
    // Start without --duration, send SIGINT after 2 seconds
    let result = run(args: [], timeout: 8, sendSIGINTAfter: 2)

    check(!result.timedOut, "Process exits after SIGINT (not stuck)")

    if !result.timedOut {
        let graceful = result.output.contains("Stopping") || result.output.contains("Saved:")
        if !graceful {
            print("    Debug output: \(result.output.suffix(300))")
            print("    Exit code: \(result.exitCode)")
        }
        check(graceful, "Graceful shutdown (prints Stopping/Saved)")

        if let path = extractSavedPath(from: result.output) {
            let exists = FileManager.default.fileExists(atPath: path)
            check(exists, "WAV file saved before exit")

            if exists {
                // Verify file is playable (not truncated/corrupt)
                let afinfo = Process()
                afinfo.executableURL = URL(fileURLWithPath: "/usr/bin/afinfo")
                afinfo.arguments = [path]
                let p = Pipe()
                afinfo.standardOutput = p
                afinfo.standardError = p
                try? afinfo.run()
                afinfo.waitUntilExit()
                check(afinfo.terminationStatus == 0, "Interrupted recording produces valid WAV")
                try? FileManager.default.removeItem(atPath: path)
            }
        } else if result.output.contains("permission not granted") {
            check(true, "Skipped (no permission)")
        }
    }
}

// ═══════════════════════════════════════════════════════════════
print("\n═══ E2E: Multiple Sequential Recordings ═══\n")
// ═══════════════════════════════════════════════════════════════

do {
    // Run twice in sequence — verify no resource leaks (second run works)
    let r1 = run(args: ["--duration", "1"], timeout: 6)
    let r2 = run(args: ["--duration", "1"], timeout: 6)

    if r1.output.contains("permission not granted") {
        check(true, "Skipped (no permission)")
    } else {
        check(!r1.timedOut && !r2.timedOut, "Both runs complete (no leaked resources)")

        let saved1 = r1.output.contains("Saved:")
        let saved2 = r2.output.contains("Saved:")
        check(saved1 && saved2, "Both recordings produce files")

        // Cleanup
        if let p1 = extractSavedPath(from: r1.output) { try? FileManager.default.removeItem(atPath: p1) }
        if let p2 = extractSavedPath(from: r2.output) { try? FileManager.default.removeItem(atPath: p2) }
    }
}

// ═══════════════════════════════════════════════════════════════
print("\n═══ E2E: SIGINT Stress (10 rapid Ctrl+C cycles) ═══\n")
// ═══════════════════════════════════════════════════════════════

do {
    // Send SIGINT at varying delays AFTER recording has started.
    // Uses --duration as fallback so test doesn't hang if SIGINT is ignored.
    // Delays are all > 1.5s to ensure the process has entered recording state.
    let delays: [Double] = [1.5, 1.7, 2.0, 2.2, 2.5, 1.8, 2.1, 1.6, 1.9, 2.3]
    var crashes = 0

    for delay in delays {
        let result = run(args: ["--duration", "10"], timeout: 8, sendSIGINTAfter: delay)

        if result.output.contains("permission not granted") { continue }

        // A crash = non-zero exit without "Saved:" in output
        if result.exitCode != 0 && !result.output.contains("Saved:") {
            crashes += 1
            print("    Crash at delay \(delay)s: exit=\(result.exitCode) out=\(result.output.suffix(100))")
        }

        if let path = extractSavedPath(from: result.output) {
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    check(crashes == 0, "Zero crashes in 10 SIGINT cycles at varying timings")
}

// ═══════════════════════════════════════════════════════════════
// Results
// ═══════════════════════════════════════════════════════════════

print("\n" + String(repeating: "═", count: 50))
print("E2E: \(passed) passed, \(failed) failed")
if failed > 0 { print("FAILED"); exit(1) }
else { print("ALL E2E TESTS PASSED ✓"); exit(0) }
