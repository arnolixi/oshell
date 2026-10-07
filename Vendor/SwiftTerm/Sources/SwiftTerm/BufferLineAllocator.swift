import Foundation
#if os(macOS)
import Darwin
#endif

/// Scrollback cells use page-backed slabs on macOS. Unlike malloc's shared
/// free-page cache, an empty slab can be returned to the OS immediately. Lines
/// own this allocator; neither the shared lookup nor a slab owns a line.
final class BufferLineAllocator {
    private static let lock = NSLock()
    private static weak var current: BufferLineAllocator?

    static func acquire() -> BufferLineAllocator {
        lock.lock(); defer { lock.unlock() }
        if let current { return current }
        let allocator = BufferLineAllocator(); current = allocator; return allocator
    }

#if os(macOS)
    private final class Slab {
        let base: UnsafeMutableRawPointer, length: Int, slotSize: Int, capacity: Int
        var freeSlots: [Int]
        init(slotSize: Int) {
            self.slotSize = slotSize
            let page = Int(getpagesize()), minimum = max(256 * 1024, slotSize)
            precondition(minimum <= Int.max - page)
            length = ((minimum + page - 1) / page) * page
            capacity = length / slotSize
            guard let raw = mmap(nil, length, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0), raw != MAP_FAILED else {
                fatalError("Unable to allocate terminal line storage")
            }
            base = raw; freeSlots = Array((0..<capacity).reversed())
        }
        deinit { munmap(base, length) }
    }
    private let storageLock = NSLock()
    private var available: [Int: [Slab]] = [:]
    private var allocations: [UInt: Slab] = [:]
#endif
    private init() {}

    func allocate(capacity: Int) -> UnsafeMutableBufferPointer<CharData> {
        precondition(capacity >= 0)
#if os(macOS)
        guard capacity > 0 else { return UnsafeMutableBufferPointer(start: nil, count: 0) }
        let (bytes, overflow) = capacity.multipliedReportingOverflow(by: MemoryLayout<CharData>.stride)
        precondition(!overflow && bytes <= Int.max - 255)
        // Small size classes avoid one VM page per row and cap rounding overhead.
        let slotSize = ((bytes + 255) / 256) * 256
        storageLock.lock(); defer { storageLock.unlock() }
        let slab: Slab
        if let cached = available[slotSize]?.last { slab = cached }
        else { slab = Slab(slotSize: slotSize); available[slotSize, default: []].append(slab) }
        let index = slab.freeSlots.removeLast()
        if slab.freeSlots.isEmpty { available[slotSize]?.removeLast() }
        let raw = slab.base.advanced(by: index * slotSize)
        allocations[UInt(bitPattern: raw)] = slab
        return UnsafeMutableBufferPointer(start: raw.bindMemory(to: CharData.self, capacity: capacity), count: capacity)
#else
        return .allocate(capacity: capacity)
#endif
    }

    func deallocate(_ buffer: UnsafeMutableBufferPointer<CharData>) {
#if os(macOS)
        guard let base = buffer.baseAddress else { return }
        storageLock.lock(); defer { storageLock.unlock() }
        guard let slab = allocations.removeValue(forKey: UInt(bitPattern: base)) else { preconditionFailure("Unknown terminal line storage") }
        let wasFull = slab.freeSlots.isEmpty
        let offset = Int(bitPattern: base) - Int(bitPattern: slab.base)
        slab.freeSlots.append(offset / slab.slotSize)
        if slab.freeSlots.count == slab.capacity {
            // The last cell buffer in this mapping has been deinitialized.
            // Dropping it unmaps its pages even if other terminals remain open.
            available[slab.slotSize]?.removeAll { $0 === slab }
            if available[slab.slotSize]?.isEmpty == true { available.removeValue(forKey: slab.slotSize) }
        } else if wasFull { available[slab.slotSize, default: []].append(slab) }
#else
        buffer.deallocate()
#endif
    }
}
