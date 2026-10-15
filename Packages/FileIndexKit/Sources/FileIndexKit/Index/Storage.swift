import Foundation

/// A pthread reader-writer lock: many concurrent readers or one writer.
final class ReadWriteLock: @unchecked Sendable {
    private let lock: UnsafeMutablePointer<pthread_rwlock_t>

    init() {
        lock = .allocate(capacity: 1)
        lock.initialize(to: pthread_rwlock_t())
        pthread_rwlock_init(lock, nil)
    }

    deinit {
        pthread_rwlock_destroy(lock)
        lock.deallocate()
    }

    func withReadLock<T>(_ body: () throws -> T) rethrows -> T {
        pthread_rwlock_rdlock(lock)
        defer { pthread_rwlock_unlock(lock) }
        return try body()
    }

    func withWriteLock<T>(_ body: () throws -> T) rethrows -> T {
        pthread_rwlock_wrlock(lock)
        defer { pthread_rwlock_unlock(lock) }
        return try body()
    }
}

/// A growable, manually managed array of plain values. Growing may move the storage, so pointers
/// taken from `base` are only valid until the next `grow`.
struct Column<Element: BitwiseCopyable> {
    private(set) var base: UnsafeMutablePointer<Element>
    private(set) var capacity: Int

    init(fill: Element) {
        base = .allocate(capacity: 1)
        base.initialize(to: fill)
        capacity = 1
    }

    /// Grows to at least `minimumCapacity`, filling new elements with `fill`.
    mutating func grow(to minimumCapacity: Int, fill: Element) {
        guard minimumCapacity > capacity else { return }
        let newCapacity = max(minimumCapacity, capacity + capacity / 2, 1024)
        let stride = MemoryLayout<Element>.stride
        guard let raw = realloc(UnsafeMutableRawPointer(base), newCapacity * stride) else {
            fatalError("Out of memory growing index column to \(newCapacity) elements")
        }
        base = raw.bindMemory(to: Element.self, capacity: newCapacity)
        (base + capacity).initialize(repeating: fill, count: newCapacity - capacity)
        capacity = newCapacity
    }

    func deallocate() {
        free(UnsafeMutableRawPointer(base))
    }
}
