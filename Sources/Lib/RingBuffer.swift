import Foundation
import os

/// Ring buffer for Float32 audio samples with overflow-drops-oldest policy.
///
/// Thread safety: uses `OSAllocatedUnfairLock` to serialize all access.
/// The lock is uncontended in the common case (producer and consumer alternate),
/// making it effectively zero-cost. Correct on both x86_64 and ARM64.
///
/// Synchronization contract (`@unchecked Sendable` justification):
/// - All mutable state (head, tail, storage contents) is accessed only
///   while holding `lock`. Producer (captureQueue) and consumer (writer thread)
///   never hold the lock simultaneously in practice (alternating access pattern).
public final class RingBuffer: @unchecked Sendable {
    private let storage: UnsafeMutablePointer<Float>
    private let mask: Int
    private let cap: Int
    private var head: Int = 0
    private var tail: Int = 0
    private let lock = OSAllocatedUnfairLock()

    public init(capacity: Int) {
        let powerOf2 = Self.nextPowerOf2(capacity)
        self.cap = powerOf2
        self.mask = powerOf2 - 1
        self.storage = .allocate(capacity: powerOf2)
        self.storage.initialize(repeating: 0, count: powerOf2)
    }

    deinit {
        storage.deinitialize(count: cap)
        storage.deallocate()
    }

    public var capacity: Int { cap }

    public var availableToRead: Int {
        lock.lock()
        let v = availableUnlocked
        lock.unlock()
        return v
    }

    public var availableToWrite: Int {
        lock.lock()
        let v = cap - 1 - availableUnlocked
        lock.unlock()
        return v
    }

    private var availableUnlocked: Int {
        (head &- tail) & mask
    }

    /// Write samples. If space is insufficient, drops oldest data to make room.
    public func write(_ samples: [Float]) {
        guard !samples.isEmpty else { return }

        samples.withUnsafeBufferPointer { src in
            lock.lock()

            let count = src.count
            let maxUsable = cap - 1
            let writeCount: Int
            let srcStart: Int

            if count >= maxUsable {
                writeCount = maxUsable
                srcStart = count - maxUsable
                tail = 0
                head = 0
            } else {
                writeCount = count
                srcStart = 0
                let spaceNeeded = count - (cap - 1 - availableUnlocked)
                if spaceNeeded > 0 {
                    tail = (tail &+ spaceNeeded) & mask
                }
            }

            var remaining = writeCount
            var srcOffset = srcStart
            var dstPos = head & mask

            while remaining > 0 {
                let chunk = min(remaining, cap - dstPos)
                storage.advanced(by: dstPos)
                    .update(from: src.baseAddress!.advanced(by: srcOffset), count: chunk)
                dstPos = (dstPos + chunk) & mask
                srcOffset += chunk
                remaining -= chunk
            }

            head = (head &+ writeCount) & mask
            lock.unlock()
        }
    }

    /// Read up to `count` samples. Returns fewer if not enough available.
    public func read(count requested: Int) -> [Float] {
        lock.lock()

        let avail = availableUnlocked
        let count = min(requested, avail)
        guard count > 0 else {
            lock.unlock()
            return []
        }

        let output = [Float](unsafeUninitializedCapacity: count) { dst, initializedCount in
            var remaining = count
            var dstOffset = 0
            var srcPos = tail & mask

            while remaining > 0 {
                let chunk = min(remaining, cap - srcPos)
                dst.baseAddress!.advanced(by: dstOffset)
                    .update(from: storage.advanced(by: srcPos), count: chunk)
                srcPos = (srcPos + chunk) & mask
                dstOffset += chunk
                remaining -= chunk
            }
            initializedCount = count
        }

        tail = (tail &+ count) & mask
        lock.unlock()
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
