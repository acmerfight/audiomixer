import AVFoundation
import CoreMedia
import os
import ScreenCaptureKit

/// Captures system audio and microphone via ScreenCaptureKit, mixes them,
/// and writes the result as a WAV file.
///
/// Architecture:
///   - SCStream callbacks write PCM into lock-free ring buffers (real-time safe)
///   - A dedicated writer thread drains both buffers, mixes, and writes to disk
///
/// Synchronization contract (`@unchecked Sendable` justification):
///   - `systemRing`, `micRing`: thread-safe (internal os_unfair_lock). Producer = `captureQueue`.
///     Consumer = writer thread, then `stop()` after thread exits.
///   - `isRunningLock`: OSAllocatedUnfairLock<Bool>, safe across threads.
///   - `stream`, `writer`, `writerThread`: mutated only in `start()`/`stop()`,
///     called sequentially from the main async context. `stop()` waits for writer
///     thread to finish before accessing ring buffers (no SPSC violation).
///   - `processSystemAudio`/`processMicrophoneAudio`: run exclusively on `captureQueue` (serial).
///   - `drainAndWrite`: called from writer thread during recording, then from `stop()`
///     only after writer thread has exited (`writerThread.isFinished == true`).
public final class CaptureEngine: NSObject, @unchecked Sendable {
    private let outputURL: URL
    private let sampleRate: UInt32 = 48000
    private let channels: UInt16 = 2

    private var stream: SCStream?
    private var writer: WAVWriter?

    // Ring buffers decouple real-time callbacks from disk I/O
    private let systemRing = RingBuffer(capacity: 48000 * 2 * 10) // 10 seconds stereo
    private let micRing = RingBuffer(capacity: 48000 * 2 * 10)

    // Aligned draining replaces broken drift-based compensation
    private let drainer = AlignedDrainer(sampleRate: 48000, channels: 2)

    // Writer thread — `isRunning` is accessed from main (stop) and writer thread,
    // protected by os_unfair_lock for ARM64 correctness.
    private var writerThread: Thread?
    private let isRunningLock = OSAllocatedUnfairLock(initialState: false)

    // Dispatch queue for SCStreamOutput (serial, non-main)
    private let captureQueue = DispatchQueue(label: "com.audiorecorder.capture", qos: .userInteractive)

    public init(outputURL: URL) {
        self.outputURL = outputURL
        super.init()
    }

    public func start() async throws {
        writer = try WAVWriter(url: outputURL, sampleRate: sampleRate, channels: channels, bitsPerSample: 16)

        let content = try await SCShareableContent.current
        guard let display = content.displays.first else {
            throw CaptureError.noDisplay
        }

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let config = SCStreamConfiguration()

        // Minimize video — we only want audio
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(Int32.max))
        config.showsCursor = false

        // System audio
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = Int(sampleRate)
        config.channelCount = Int(channels)

        // Microphone (macOS 15+)
        config.captureMicrophone = true
        if let mic = AVCaptureDevice.default(for: .audio) {
            config.microphoneCaptureDeviceID = mic.uniqueID
        } else {
            config.captureMicrophone = false
        }

        stream = SCStream(filter: filter, configuration: config, delegate: self)
        guard let stream else { throw CaptureError.streamCreationFailed }

        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: captureQueue)
        if config.captureMicrophone {
            try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: captureQueue)
        }

        // Start writer thread before capture to avoid losing initial samples
        isRunningLock.withLock { $0 = true }
        let thread = Thread { [weak self] in self?.writerLoop() }
        thread.qualityOfService = .userInitiated
        thread.name = "com.audiorecorder.writer"
        writerThread = thread
        thread.start()

        try await stream.startCapture()
    }

    public func stop() async {
        if let stream {
            try? await stream.stopCapture()
            self.stream = nil
        }

        // Signal writer thread to finish and wait for it to exit
        isRunningLock.withLock { $0 = false }
        while writerThread?.isFinished == false {
            try? await Task.sleep(for: .milliseconds(10))
        }
        writerThread = nil

        // Final drain — safe because writer thread has exited (no SPSC violation)
        drainAndWrite(flush: true)
        writer?.finalize()
        writer = nil
    }

    // MARK: - Writer Thread

    private func writerLoop() {
        while isRunningLock.withLock({ $0 }) {
            drainAndWrite(flush: false)
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    private func drainAndWrite(flush: Bool) {
        while true {
            let result = drainer.drain(system: systemRing, mic: micRing, flush: flush)

            if result.system.isEmpty && result.mic.isEmpty { break }

            let mixed = AudioMixer.mix(system: result.system, mic: result.mic)
            writer?.write(samples: AudioMixer.toInt16(mixed))

            if flush { break }
        }
    }
}

// MARK: - SCStreamOutput

extension CaptureEngine: SCStreamOutput {
    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }

        switch type {
        case .screen:
            break
        case .audio:
            processSystemAudio(sampleBuffer)
        case .microphone:
            processMicrophoneAudio(sampleBuffer)
        @unknown default:
            break
        }
    }

    private func processSystemAudio(_ buffer: CMSampleBuffer) {
        guard let pcm = extractInterleavedFloat32(from: buffer) else { return }
        systemRing.write(pcm)
    }

    private func processMicrophoneAudio(_ buffer: CMSampleBuffer) {
        guard let formatDesc = buffer.formatDescription,
              let asbd = formatDesc.audioStreamBasicDescription else { return }

        guard var pcm = extractInterleavedFloat32(from: buffer) else { return }

        let sourceRate = Int(asbd.mSampleRate)
        let sourceChannels = Int(asbd.mChannelsPerFrame)

        // Resample to target format if needed
        if sourceRate != Int(sampleRate) {
            pcm = Resampler.resample(pcm, fromRate: sourceRate, toRate: Int(sampleRate), channels: sourceChannels)
        }

        // Convert mono to stereo if needed
        if sourceChannels == 1 && channels == 2 {
            let stereo = [Float](unsafeUninitializedCapacity: pcm.count * 2) { buf, count in
                for i in 0..<pcm.count {
                    buf[i * 2] = pcm[i]
                    buf[i * 2 + 1] = pcm[i]
                }
                count = pcm.count * 2
            }
            pcm = stereo
        }

        micRing.write(pcm)
    }

    private func extractInterleavedFloat32(from sampleBuffer: CMSampleBuffer) -> [Float]? {
        guard let formatDesc = sampleBuffer.formatDescription,
              let asbd = formatDesc.audioStreamBasicDescription else { return nil }

        // Query the required buffer list size first (handles non-interleaved multi-channel)
        var bufferListSize: Int = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &bufferListSize,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: nil
        )
        guard bufferListSize > 0 else { return nil }

        let abl = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: bufferListSize / MemoryLayout<AudioBufferList>.stride + 1)
        defer { abl.deallocate() }

        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: abl,
            bufferListSize: bufferListSize,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr else { return nil }

        let frameCount = Int(sampleBuffer.numSamples)
        let channelCount = Int(asbd.mChannelsPerFrame)
        let bufferList = UnsafeMutableAudioBufferListPointer(abl)

        if asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0 {
            // Non-interleaved: each buffer is one channel
            var interleaved = [Float](repeating: 0, count: frameCount * channelCount)
            for ch in 0..<min(channelCount, bufferList.count) {
                guard let data = bufferList[ch].mData else { continue }
                let ptr = data.assumingMemoryBound(to: Float.self)
                for frame in 0..<frameCount {
                    interleaved[frame * channelCount + ch] = ptr[frame]
                }
            }
            return interleaved
        } else {
            // Interleaved: single buffer
            guard let data = bufferList[0].mData else { return nil }
            let count = Int(bufferList[0].mDataByteSize) / MemoryLayout<Float>.size
            let ptr = data.assumingMemoryBound(to: Float.self)
            return Array(UnsafeBufferPointer(start: ptr, count: count))
        }
    }
}

// MARK: - SCStreamDelegate

extension CaptureEngine: SCStreamDelegate {
    public func stream(_ stream: SCStream, didStopWithError error: any Error) {
        fputs("Stream error: \(error.localizedDescription)\n", stderr)
    }
}

// MARK: - Errors

public enum CaptureError: Error, LocalizedError {
    case noDisplay
    case streamCreationFailed

    public var errorDescription: String? {
        switch self {
        case .noDisplay: return "No display found"
        case .streamCreationFailed: return "Failed to create SCStream"
        }
    }
}
