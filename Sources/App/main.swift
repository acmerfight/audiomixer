import Foundation
import AudioRecorderLib

struct App {
    static func run() async {
        let duration = parseDuration()
        let outputURL = makeOutputURL()
        let engine = CaptureEngine(outputURL: outputURL)

        let stopSignal = installSignalHandler()

        do {
            try await engine.start()
            fputs("Recording to: \(outputURL.path)\n", stderr)
            if let d = duration {
                fputs("Duration: \(d)s (or Ctrl+C to stop early)\n", stderr)
            } else {
                fputs("Press Ctrl+C to stop\n", stderr)
            }

            if let duration {
                await race(
                    { await stopSignal() },
                    { try? await Task.sleep(for: .seconds(duration)) }
                )
            } else {
                await stopSignal()
            }

            fputs("\nStopping...\n", stderr)
            await engine.stop()
            fputs("Saved: \(outputURL.path)\n", stderr)
        } catch {
            fputs("Error: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
        exit(0)
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

    private static func installSignalHandler() -> @Sendable () async -> Void {
        return {
            await withCheckedContinuation { continuation in
                signal(SIGINT, SIG_IGN)
                let src = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
                src.setEventHandler {
                    src.cancel()
                    continuation.resume()
                }
                src.resume()
            }
        }
    }

    private static func race(_ a: @escaping @Sendable () async -> Void, _ b: @escaping @Sendable () async -> Void) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await a() }
            group.addTask { await b() }
            await group.next()
            group.cancelAll()
        }
    }
}

let sem = DispatchSemaphore(value: 0)
Task { await App.run(); sem.signal() }
sem.wait()
