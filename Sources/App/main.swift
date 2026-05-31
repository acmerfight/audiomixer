import Foundation
import ScreenCaptureKit
import AudioRecorderLib

nonisolated(unsafe) var globalStopped = false

private func signalHandler(_: Int32) {
    globalStopped = true
}

@main
struct AudioRecorderCLI {
    static func main() async {
        // Preflight: check Screen Recording permission with timeout
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

        let duration = parseDuration()
        let outputURL = makeOutputURL()
        let engine = CaptureEngine(outputURL: outputURL)

        signal(SIGINT, signalHandler)
        signal(SIGTERM, signalHandler)

        do {
            try await engine.start()
            fputs("Recording to: \(outputURL.path)\n", stderr)
            if let d = duration {
                fputs("Duration: \(d)s (or Ctrl+C to stop early)\n", stderr)
            } else {
                fputs("Press Ctrl+C to stop\n", stderr)
            }

            let startTime = Date()
            while !globalStopped {
                try? await Task.sleep(for: .milliseconds(100))
                if let d = duration, Date().timeIntervalSince(startTime) >= Double(d) {
                    break
                }
            }

            fputs("\nStopping...\n", stderr)
            await engine.stop()
            fputs("Saved: \(outputURL.path)\n", stderr)
        } catch {
            fputs("Error: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

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

    private static func parseDuration() -> Int? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--duration"),
              i + 1 < args.count,
              let v = Int(args[i + 1]), v > 0 else { return nil }
        return v
    }

    private static func makeOutputURL() -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let name = "recording_\(formatter.string(from: Date())).wav"
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(name)
    }
}
