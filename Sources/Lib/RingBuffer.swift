import Foundation
import os

/// Ring buffer for Float32 audio samples with overflow-drops-oldest policy.
///
/// Thread safety: uses `os_unfair_lock` to serialize all access.
/// Correct on both x86_64 and ARM64. Lock hold time is bounded
/// (index math + memcpy of at most ~4KB per call at 48kHz).
public final class RingBuffer: @unchecked Sendable {
    private let storage: UnsafeMutablePointer<Float>
    private let mask: Int
    private let cap: Int
    private var head: Int = 0
    private var tail: Int = 0
    private var _lock = os_unfair_lock()

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
        os_unfair_lock_lock(&_lock)
        let v = availableUnlocked
        os_unfair_lock_unlock(&_lock)
        return v
    }

    public var availableToWrite: Int {
        os_unfair_lock_lock(&_lock)
        let v = cap - 1 - availableUnlocked
        os_unfair_lock_unlock(&_lock)
        return v
    }

    private var availableUnlocked: Int {
        (head &- tail) & mask
    }

    public func write(_ samples: [Float]) {
        guard !samples.isEmpty else { return }

        samples.withUnsafeBufferPointer { src in
            os_unfair_lock_lock(&_lock)

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
            os_unfair_lock_unlock(&_lock)
        }
    }

    public func read(count requested: Int) -> [Float] {
        os_unfair_lock_lock(&_lock)

        let avail = availableUnlocked
        let count = min(requested, avail)
        guard count > 0 else {
            os_unfair_lock_unlock(&_lock)
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
        os_unfair_lock_unlock(&_lock)
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
