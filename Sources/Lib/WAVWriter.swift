import Foundation

/// Writes PCM audio data to a WAV file with automatic RF64 upgrade (EBU Tech 3306).
///
/// Behavior:
/// - Starts as a standard RIFF/WAVE file with a JUNK placeholder chunk.
/// - If data exceeds 4GB, upgrades in-place to RF64 format:
///   RIFF→RF64, JUNK→ds64, size fields set to 0xFFFFFFFF.
/// - Files under 4GB are fully standard WAV — the JUNK chunk is ignored by all players.
/// - macOS Core Audio natively reads RF64 (afplay, afconvert, AVAudioFile).
///
/// Synchronization contract (`@unchecked Sendable` justification):
/// - All mutable state and FileHandle operations occur exclusively on the writer thread.
/// - `write(samples:)` is called only from `CaptureEngine.drainAndWrite()`.
/// - `finalize()` is called only from `CaptureEngine.stop()` after the writer thread exits.
public final class WAVWriter: @unchecked Sendable {
    private let fileHandle: FileHandle
    private let sampleRate: UInt32
    private let channels: UInt16
    private let bitsPerSample: UInt16
    private var dataSize: UInt64 = 0
    private var upgradedToRF64 = false

    // Header layout offsets (verified by byte-counting):
    //   0: RIFF(4) + size(4) + WAVE(4) = 12
    //  12: JUNK(4) + size(4) + body(28) = 36  → ends at 48
    //  48: fmt_(4) + size(4) + body(16) = 24  → ends at 72
    //  72: data(4) + size(4) = 8              → PCM starts at 80
    private static let riffIDOffset: UInt64 = 0
    private static let riffSizeOffset: UInt64 = 4
    private static let junkIDOffset: UInt64 = 12
    private static let ds64DataOffset: UInt64 = 20
    private static let dataSizeOffset: UInt64 = 76
    private static let headerSize: UInt64 = 80

    // ds64 chunk body is 28 bytes: riffSize(8) + dataSize(8) + sampleCount(8) + tableLength(4)
    private static let ds64BodySize: UInt32 = 28
    private static let fourGBThreshold: UInt64 = UInt64(UInt32.max)

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
            dataSize += UInt64(data.count)
        }

        // Check if we need to upgrade to RF64
        if !upgradedToRF64 && dataSize > Self.fourGBThreshold {
            upgradeToRF64()
        }
    }

    public func finalize() {
        let totalFileSize = Self.headerSize + dataSize
        let sampleCount = dataSize / UInt64(channels) / UInt64(bitsPerSample / 8)

        if upgradedToRF64 || totalFileSize > UInt64(UInt32.max) {
            // Ensure RF64 header is in place
            if !upgradedToRF64 { upgradeToRF64() }

            // Update ds64 chunk with final sizes
            fileHandle.seek(toFileOffset: Self.ds64DataOffset)
            writeUInt64(totalFileSize - 8)  // riffSize (64-bit)
            writeUInt64(dataSize)            // dataSize (64-bit)
            writeUInt64(sampleCount)         // sampleCount (64-bit)
        } else {
            // Standard RIFF/WAVE — update 32-bit size fields
            fileHandle.seek(toFileOffset: Self.riffSizeOffset)
            writeUInt32(UInt32(totalFileSize - 8))

            fileHandle.seek(toFileOffset: Self.dataSizeOffset)
            writeUInt32(UInt32(dataSize))
        }

        fileHandle.closeFile()
    }

    // MARK: - Private

    /// Writes the initial header: RIFF + JUNK(28 bytes placeholder) + fmt + data.
    /// Per EBU Tech 3306: JUNK chunk reserves space for ds64 if RF64 upgrade is needed.
    private func writeHeader() {
        let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample) / 8
        let blockAlign = channels * bitsPerSample / 8

        var header = Data(capacity: Int(Self.headerSize))

        // RIFF header (will become RF64 if file exceeds 4GB)
        header.append(ascii: "RIFF")
        header.appendUInt32(0)              // RIFF size placeholder (offset 4)
        header.append(ascii: "WAVE")

        // JUNK chunk — same size as ds64, per EBU Tech 3306 section 3.5
        // Will be overwritten with "ds64" if RF64 upgrade occurs
        header.append(ascii: "JUNK")        // offset 12
        header.appendUInt32(Self.ds64BodySize) // chunk size = 28
        header.append(Data(repeating: 0, count: Int(Self.ds64BodySize))) // 28 zero bytes (offset 20-47)

        // fmt chunk (offset 48)
        header.append(ascii: "fmt ")
        header.appendUInt32(16)
        header.appendUInt16(1)              // PCM format tag
        header.appendUInt16(channels)
        header.appendUInt32(sampleRate)
        header.appendUInt32(byteRate)
        header.appendUInt16(blockAlign)
        header.appendUInt16(bitsPerSample)

        // data chunk (offset 72, size field at 76, PCM starts at 80)
        header.append(ascii: "data")
        header.appendUInt32(0)

        // Total: 84 bytes
        fileHandle.write(header)
    }

    /// Upgrades the file from RIFF/WAVE to RF64 in-place (EBU Tech 3306 section 3.5).
    private func upgradeToRF64() {
        guard !upgradedToRF64 else { return }
        upgradedToRF64 = true

        let currentPos = fileHandle.offsetInFile

        // 1. Replace "RIFF" with "RF64"
        fileHandle.seek(toFileOffset: Self.riffIDOffset)
        fileHandle.write(Data("RF64".utf8))

        // 2. Set RIFF size to 0xFFFFFFFF
        fileHandle.seek(toFileOffset: Self.riffSizeOffset)
        writeUInt32(0xFFFFFFFF)

        // 3. Replace "JUNK" with "ds64"
        fileHandle.seek(toFileOffset: Self.junkIDOffset)
        fileHandle.write(Data("ds64".utf8))

        // 4. Set data chunk size to 0xFFFFFFFF
        fileHandle.seek(toFileOffset: Self.dataSizeOffset)
        writeUInt32(0xFFFFFFFF)

        // Restore write position
        fileHandle.seek(toFileOffset: currentPos)
    }

    private func writeUInt32(_ value: UInt32) {
        var le = value.littleEndian
        fileHandle.write(Data(bytes: &le, count: 4))
    }

    private func writeUInt64(_ value: UInt64) {
        var le = value.littleEndian
        fileHandle.write(Data(bytes: &le, count: 8))
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
