import Foundation

/// Lock-free single-producer single-consumer ring buffer for Float32 audio samples.
///
/// Overflow policy: when full, **drops oldest data** to make room for new writes.
/// This ensures the most recent audio is always preserved — critical for recording
/// where losing the latest content is worse than losing old buffered content.
///
/// Thread safety: designed for exactly one writer thread and one reader thread.
/// On x86_64 (TSO), plain loads/stores are sufficient for SPSC correctness.
/// On ARM (weak memory model), this would require atomic acquire/release barriers.
public final class RingBuffer: @unchecked Sendable {
    private let storage: UnsafeMutablePointer<Float>
    private let mask: Int
    private var head: Int = 0
    private var tail: Int = 0
    private let cap: Int

    /// Creates a ring buffer. Capacity is rounded up to next power of 2.
    public init(capacity: Int) {
        let powerOf2 = Self.nextPowerOf2(capacity)
        self.cap = powerOf2
        self.mask = powerOf2 - 1
        self.storage = .allocate(capacity: powerOf2)
        self.storage.initialize(repeating: 0, count: powerOf2)
    }

    deinit {
        storage.deallocate()
    }

    public var capacity: Int { cap }

    public var availableToRead: Int {
        (head - tail + cap) & mask
    }

    public var availableToWrite: Int {
        cap - 1 - availableToRead
    }

    /// Write samples into the buffer.
    /// If there isn't enough space, **advances tail (drops oldest)** to make room.
    public func write(_ samples: [Float]) {
        guard !samples.isEmpty else { return }

        let count = samples.count
        let maxUsable = cap - 1

        if count >= maxUsable {
            // Writing more than buffer can hold: keep only the last maxUsable samples
            samples.withUnsafeBufferPointer { src in
                let offset = count - maxUsable
                let writeStart = head & mask
                let firstChunk = min(maxUsable, cap - writeStart)
                storage.advanced(by: writeStart)
                    .update(from: src.baseAddress!.advanced(by: offset), count: firstChunk)
                if firstChunk < maxUsable {
                    storage.update(from: src.baseAddress!.advanced(by: offset + firstChunk), count: maxUsable - firstChunk)
                }
            }
            head = (head + maxUsable) & mask
            tail = (head + 1) & mask
            return
        }

        // Check if we need to drop oldest to make room
        let spaceNeeded = count - availableToWrite
        if spaceNeeded > 0 {
            tail = (tail + spaceNeeded) & mask
        }

        // Write the data
        samples.withUnsafeBufferPointer { src in
            var remaining = count
            var srcOffset = 0
            var writePos = head & mask

            while remaining > 0 {
                let chunk = min(remaining, cap - writePos)
                storage.advanced(by: writePos)
                    .update(from: src.baseAddress!.advanced(by: srcOffset), count: chunk)
                writePos = (writePos + chunk) & mask
                srcOffset += chunk
                remaining -= chunk
            }

            head = (head + count) & mask
        }
    }

    /// Read up to `count` samples. Returns fewer if not enough available.
    public func read(count requested: Int) -> [Float] {
        let count = min(requested, availableToRead)
        guard count > 0 else { return [] }

        let output = [Float](unsafeUninitializedCapacity: count) { dst, initializedCount in
            var remaining = count
            var dstOffset = 0
            var readPos = tail & mask

            while remaining > 0 {
                let chunk = min(remaining, cap - readPos)
                dst.baseAddress!.advanced(by: dstOffset)
                    .update(from: storage.advanced(by: readPos), count: chunk)
                readPos = (readPos + chunk) & mask
                dstOffset += chunk
                remaining -= chunk
            }
            initializedCount = count
        }

        tail = (tail + count) & mask
        return output
    }

    private static func nextPowerOf2(_ n: Int) -> Int {
        var v = n - 1
        v |= v >> 1
        v |= v >> 2
        v |= v >> 4
        v |= v >> 8
        v |= v >> 16
        v |= v >> 32
        return v + 1
    }
}
