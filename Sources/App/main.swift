import Foundation
import ScreenCaptureKit
import AudioRecorderLib

@main
struct AudioRecorderCLI {
    static func main() async {
        let args = CommandLine.arguments

        if args.contains("--help") || args.contains("-h") {
            printUsage()
            exit(0)
        }

        // Ignore signals immediately at startup to prevent early termination
        // during permission checks. Proper handling is installed later.
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)

        fputs("Checking permissions...\n", stderr)

        let permitted = await checkScreenRecordingPermission()

        if !permitted {
            fputs("""
            ERROR: Screen Recording permission not granted.

            Fix:
              1. Open System Settings → Privacy & Security → Screen & System Audio Recording
              2. Enable your terminal app (Terminal.app / iTerm2 / etc.)
              3. Restart your terminal completely
              4. Run this command again

            Note: macOS hangs indefinitely without this permission — no prompt is shown for CLI tools.

            """, stderr)
            exit(1)
        }
        fputs("Permissions OK.\n", stderr)

        let duration = parseIntOption("--duration", from: args)
        let outputURL = resolveOutputURL(from: args)

        // Verify output directory is writable before starting capture
        let outputDir = outputURL.deletingLastPathComponent().path
        guard FileManager.default.isWritableFile(atPath: outputDir) else {
            fputs("Error: output directory is not writable: \(outputDir)\n", stderr)
            exit(1)
        }

        let engine = CaptureEngine(outputURL: outputURL)

        do {
            try await engine.start()
            fputs("Recording to: \(outputURL.path)\n", stderr)
            if let d = duration {
                fputs("Duration: \(d)s (or Ctrl+C to stop early)\n", stderr)
            } else {
                fputs("Press Ctrl+C to stop\n", stderr)
            }

            await waitForStopSignal(duration: duration)

            fputs("\nStopping...\n", stderr)
            await engine.stop()
            fputs("Saved: \(outputURL.path)\n", stderr)
        } catch {
            fputs("Error: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    // MARK: - Usage

    private static func printUsage() {
        let usage = """
        USAGE: audiomixer [OPTIONS]

        Record system audio and microphone into a single WAV file.

        OPTIONS:
          --duration <seconds>    Stop after specified duration (default: record until Ctrl+C)
          --output <path>         Output file path (default: recording_YYYYMMDD_HHMMSS.wav)
          --help, -h              Show this help message

        EXAMPLES:
          audiomixer                                  Record until Ctrl+C
          audiomixer --duration 60                    Record for 60 seconds
          audiomixer --output ~/meeting.wav           Save to specific path
          audiomixer --duration 300 --output /tmp/rec.wav

        OUTPUT FORMAT:
          WAV (PCM Int16, 48kHz, Stereo). Automatically upgrades to RF64 if >4GB.

        PERMISSIONS:
          Requires Screen & System Audio Recording + Microphone permissions.
          Grant in: System Settings → Privacy & Security
          Restart terminal after granting.

        """
        fputs(usage, stderr)
    }

    // MARK: - Argument Parsing

    private static func parseIntOption(_ name: String, from args: [String]) -> Int? {
        guard let i = args.firstIndex(of: name),
              i + 1 < args.count,
              let v = Int(args[i + 1]), v > 0 else { return nil }
        return v
    }

    private static func parseStringOption(_ name: String, from args: [String]) -> String? {
        guard let i = args.firstIndex(of: name),
              i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    private static func resolveOutputURL(from args: [String]) -> URL {
        if let path = parseStringOption("--output", from: args) {
            return URL(fileURLWithPath: path)
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let name = "recording_\(formatter.string(from: Date())).wav"
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(name)
    }

    // MARK: - Signal Handling

    private static func waitForStopSignal(duration: Int?) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let queue = DispatchQueue(label: "com.audiorecorder.signal")

            var resumed = false
            let sigSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: queue)
            var termSource: DispatchSourceSignal?
            var timer: DispatchSourceTimer?

            let resumeOnce = {
                guard !resumed else { return }
                resumed = true
                sigSource.cancel()
                termSource?.cancel()
                timer?.cancel()
                continuation.resume()
            }

            sigSource.setEventHandler { resumeOnce() }
            sigSource.resume()

            let ts = DispatchSource.makeSignalSource(signal: SIGTERM, queue: queue)
            ts.setEventHandler { resumeOnce() }
            ts.resume()
            termSource = ts

            if let duration {
                let t = DispatchSource.makeTimerSource(queue: queue)
                t.schedule(deadline: .now() + .seconds(duration))
                t.setEventHandler { resumeOnce() }
                t.resume()
                timer = t
            }
        }
    }

    // MARK: - Permission Check

    private static func checkScreenRecordingPermission() async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                _ = try? await SCShareableContent.current
                return true
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(3))
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }
}
