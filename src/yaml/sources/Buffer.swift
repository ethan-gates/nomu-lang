// A growable array for hot loops. `Array.append` checks capacity and uniqueness on every call; here callers
// reserve room once for a batch (a 64-byte block adds at most 64 entries) and then store without checks.
// Measured on stage 1, `Array.append` of line starts cost about 30% of throughput.
final class GrowableBuffer<Element> {
    private(set) var count = 0
    private var capacity: Int
    private var storage: UnsafeMutablePointer<Element>

    init(capacity: Int) {
        self.capacity = max(capacity, 16)
        storage = UnsafeMutablePointer<Element>.allocate(capacity: self.capacity)
    }

    deinit {
        storage.deinitialize(count: count)
        storage.deallocate()
    }

    // Ensures room for `extra` more elements.
    @inline(__always)
    func reserve(_ extra: Int) {
        if count + extra > capacity { grow(to: count + extra) }
    }

    // Appends without checking capacity; the caller has reserved room.
    @inline(__always)
    func appendReserved(_ element: Element) {
        (storage + count).initialize(to: element)
        count += 1
    }

    func append(_ element: Element) {
        reserve(1)
        appendReserved(element)
    }

    // Unchecked access to an element below `count`.
    @inline(__always)
    subscript(i: Int) -> Element {
        get { storage[i] }
        _modify { yield &storage[i] }
    }

    var last: Element? { count > 0 ? storage[count - 1] : nil }

    // Removes the last `n` elements.
    @inline(__always)
    func removeLast(_ n: Int = 1) {
        count -= n
        (storage + count).deinitialize(count: n)
    }

    var array: [Element] { Array(UnsafeBufferPointer(start: storage, count: count)) }

    @inline(never)
    private func grow(to needed: Int) {
        let newCapacity = max(needed, capacity * 2)
        let newStorage = UnsafeMutablePointer<Element>.allocate(capacity: newCapacity)
        newStorage.moveInitialize(from: storage, count: count)
        storage.deallocate()
        storage = newStorage
        capacity = newCapacity
    }
}
