import CoreServices
import Foundation

/// One file system change reported by FSEvents.
public struct FSEvent: Sendable {
    public struct Flags: OptionSet, Sendable {
        public let rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }

        public static let mustScanSubDirs = Flags(rawValue: UInt32(kFSEventStreamEventFlagMustScanSubDirs))
        public static let userDropped = Flags(rawValue: UInt32(kFSEventStreamEventFlagUserDropped))
        public static let kernelDropped = Flags(rawValue: UInt32(kFSEventStreamEventFlagKernelDropped))
        public static let eventIDsWrapped = Flags(rawValue: UInt32(kFSEventStreamEventFlagEventIdsWrapped))
        public static let historyDone = Flags(rawValue: UInt32(kFSEventStreamEventFlagHistoryDone))
        public static let rootChanged = Flags(rawValue: UInt32(kFSEventStreamEventFlagRootChanged))
        public static let mount = Flags(rawValue: UInt32(kFSEventStreamEventFlagMount))
        public static let unmount = Flags(rawValue: UInt32(kFSEventStreamEventFlagUnmount))

        /// The event stands for an unknown set of changes below its path.
        public static let needsRescan: Flags = [.mustScanSubDirs, .userDropped, .kernelDropped]
    }

    public var path: String
    public var flags: Flags
    public var id: UInt64
}

/// Wraps an FSEventStream with file-level events, delivering batches on a private queue.
public final class FSEventsWatcher: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.mrozip.iFileList.fsevents", qos: .utility)
    private let handler: @Sendable ([FSEvent]) -> Void
    private let ignoresOwnEvents: Bool
    private var stream: FSEventStreamRef?

    /// With `ignoresOwnEvents`, changes made by this process are not reported.
    public init(ignoresOwnEvents: Bool = true, handler: @escaping @Sendable ([FSEvent]) -> Void) {
        self.ignoresOwnEvents = ignoresOwnEvents
        self.handler = handler
    }

    deinit {
        stop()
    }

    /// The most recent event ID system-wide. Starting a stream from it replays nothing.
    public static var currentEventID: UInt64 { FSEventsGetCurrentEventId() }

    /// The UUID of a device's FSEvents database. If it changes, stored event IDs are meaningless.
    public static func eventDatabaseUUID(forDevice device: Int32) -> String? {
        guard let uuid = FSEventsCopyUUIDForDevice(dev_t(device)) else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }

    /// Starts watching. Events after `sinceEventID` are replayed first, then live changes follow.
    /// Paths below `excluding` (up to 8) are not reported.
    @discardableResult
    public func start(paths: [String], sinceEventID: UInt64, latency: TimeInterval = 1.0, excluding: [String] = [])
        -> Bool
    {
        stop()
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil,
            copyDescription: nil)
        var flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagNoDefer)
        if ignoresOwnEvents { flags |= FSEventStreamCreateFlags(kFSEventStreamCreateFlagIgnoreSelf) }
        guard let stream = FSEventStreamCreate(
            nil, Self.callback, &context, paths as CFArray, sinceEventID, latency, flags)
        else { return false }
        if !excluding.isEmpty {
            FSEventStreamSetExclusionPaths(stream, Array(excluding.prefix(8)) as CFArray)
        }
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return false
        }
        self.stream = stream
        return true
    }

    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private static let callback: FSEventStreamCallback = { _, info, count, paths, flags, ids in
        guard let info else { return }
        let watcher = Unmanaged<FSEventsWatcher>.fromOpaque(info).takeUnretainedValue()
        let pathArray = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
        var events: [FSEvent] = []
        events.reserveCapacity(count)
        for i in 0..<min(count, pathArray.count) {
            events.append(FSEvent(path: pathArray[i], flags: FSEvent.Flags(rawValue: flags[i]), id: ids[i]))
        }
        watcher.handler(events)
    }
}
