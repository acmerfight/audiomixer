import Foundation

/// Writes PCM audio data to a standard WAV file (RIFF/WAVE format).
/// Thread-safe for single-writer usage. Call `finalize()` to update headers before closing.
public final class WAVWriter: @unchecked Sendable {
    private let fileHandle: FileHandle
    private let sampleRate: UInt32
    private let channels: UInt16
    private let bitsPerSample: UInt16
    private var dataSize: UInt32 = 0

    public init(url: URL, sampleRate: UInt32, channels: UInt16, bitsPerSample: UInt16) throws {
        self.sampleRate = sampleRate
        self.channels = channels
        self.bitsPerSample = bitsPerSample

        FileManager.default.createFile(atPath: url.path, contents: nil)
        self.fileHandle = try FileHandle(forWritingTo: url)
        writeHeader()
    }

    public func write(samples: [Int16]) {
        samples.withUnsafeBufferPointer { ptr in
            let data = Data(bytes: ptr.baseAddress!, count: ptr.count * MemoryLayout<Int16>.size)
            fileHandle.write(data)
            dataSize += UInt32(data.count)
        }
    }

    public func finalize() {
        fileHandle.seek(toFileOffset: 40)
        writeUInt32(dataSize)

        fileHandle.seek(toFileOffset: 4)
        writeUInt32(36 + dataSize)

        fileHandle.closeFile()
    }

    // MARK: - Private

    private func writeHeader() {
        let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample) / 8
        let blockAlign = channels * bitsPerSample / 8

        var header = Data(capacity: 44)
        header.append(ascii: "RIFF")
        header.appendUInt32(0)              // RIFF size placeholder
        header.append(ascii: "WAVE")
        header.append(ascii: "fmt ")
        header.appendUInt32(16)             // PCM fmt chunk size
        header.appendUInt16(1)              // PCM format tag
        header.appendUInt16(channels)
        header.appendUInt32(sampleRate)
        header.appendUInt32(byteRate)
        header.appendUInt16(blockAlign)
        header.appendUInt16(bitsPerSample)
        header.append(ascii: "data")
        header.appendUInt32(0)              // data size placeholder

        fileHandle.write(header)
    }

    private func writeUInt32(_ value: UInt32) {
        var le = value.littleEndian
        fileHandle.write(Data(bytes: &le, count: 4))
    }
}

private extension Data {
    mutating func append(ascii: String) {
        append(contentsOf: ascii.utf8)
    }
    mutating func appendUInt32(_ value: UInt32) {
        var le = value.littleEndian
        append(Data(bytes: &le, count: 4))
    }
    mutating func appendUInt16(_ value: UInt16) {
        var le = value.littleEndian
        append(Data(bytes: &le, count: 2))
    }
}
