import Darwin

/// One item read from a directory. `name` is only valid inside the callback that receives it.
struct DirectoryItem {
    var name: UnsafeBufferPointer<UInt8>
    var isDirectory: Bool
    var isSymlink: Bool
    var device: Int32
    var size: Int64
    var mtime: Int64
    var crtime: Int64

    var flags: EntryFlags {
        var flags: EntryFlags = []
        if isDirectory { flags.insert(.directory) }
        if isSymlink { flags.insert(.symlink) }
        return flags
    }
}

/// Reads directories with `getattrlistbulk(2)`, which returns name, type, device, size and
/// modification time for many entries per system call. Falls back to `readdir` + `fstatat` on
/// file systems that don't support it. Each reader owns a buffer; use one per thread.
final class DirectoryReader {
    // Attribute bits from <sys/attr.h>, spelled out to avoid mixed-width macro imports.
    private static let commonName: attrgroup_t = 0x0000_0001
    private static let commonDevice: attrgroup_t = 0x0000_0002
    private static let commonObjectType: attrgroup_t = 0x0000_0008
    private static let commonCreationTime: attrgroup_t = 0x0000_0200
    private static let commonModificationTime: attrgroup_t = 0x0000_0400
    private static let commonError: attrgroup_t = 0x2000_0000
    private static let commonReturnedAttributes: attrgroup_t = 0x8000_0000
    private static let fileTotalSize: attrgroup_t = 0x0000_0002

    // vtype values from <sys/vnode.h>.
    private static let typeDirectory: UInt32 = 2
    private static let typeSymlink: UInt32 = 5

    private let bufferSize = 256 * 1024
    private let buffer: UnsafeMutableRawPointer

    init() {
        buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 16)
    }

    deinit {
        buffer.deallocate()
    }

    private static func attributeList(bulk: Bool) -> attrlist {
        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        list.commonattr = commonReturnedAttributes | commonName | commonDevice | commonObjectType
            | commonCreationTime | commonModificationTime | (bulk ? commonError : 0)
        list.fileattr = fileTotalSize
        return list
    }

    /// Calls `body` for each item in the directory at `path`.
    /// Returns 0 on success, or the `errno` that stopped the listing.
    @discardableResult
    func forEachItem(inDirectory path: String, _ body: (DirectoryItem) -> Void) -> Int32 {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return errno }
        defer { close(fd) }

        var list = Self.attributeList(bulk: true)
        while true {
            let count = getattrlistbulk(fd, &list, buffer, bufferSize, 0)
            if count < 0 {
                let error = errno
                if error == ENOTSUP || error == EINVAL { return readWithReaddir(fd: fd, body) }
                return error
            }
            if count == 0 { return 0 }
            var entry = UnsafeRawPointer(buffer)
            for _ in 0..<count {
                let length = Int(entry.loadUnaligned(as: UInt32.self))
                if let item = Self.parseAttributes(entry, bulk: true) { body(item) }
                entry += length
            }
        }
    }

    /// Attributes of a single item, without following a final symlink. The returned item's name
    /// points into this reader's buffer and is valid until the next call.
    func item(atPath path: String) -> DirectoryItem? {
        var list = Self.attributeList(bulk: false)
        let rc = getattrlist(path, &list, buffer, bufferSize, UInt32(FSOPT_NOFOLLOW))
        guard rc == 0 else { return nil }
        return Self.parseAttributes(UnsafeRawPointer(buffer), bulk: false)
    }

    /// Parses one packed attribute record. Attributes follow in bit order, each 4-byte aligned;
    /// the returned-attributes set says which are present.
    private static func parseAttributes(_ record: UnsafeRawPointer, bulk: Bool) -> DirectoryItem? {
        var field = record + MemoryLayout<UInt32>.size
        let returned = field.loadUnaligned(as: attribute_set_t.self)
        field += MemoryLayout<attribute_set_t>.size

        if bulk && returned.commonattr & commonError != 0 {
            field += MemoryLayout<UInt32>.size
        }
        var name = UnsafeBufferPointer<UInt8>(start: nil, count: 0)
        if returned.commonattr & commonName != 0 {
            let reference = field.loadUnaligned(as: attrreference_t.self)
            let length = Int(reference.attr_length) - 1  // excludes the NUL terminator
            if length > 0 {
                let start = (field + Int(reference.attr_dataoffset)).assumingMemoryBound(to: UInt8.self)
                name = UnsafeBufferPointer(start: start, count: length)
            }
            field += MemoryLayout<attrreference_t>.size
        }
        var device: Int32 = 0
        if returned.commonattr & commonDevice != 0 {
            device = field.loadUnaligned(as: Int32.self)
            field += MemoryLayout<Int32>.size
        }
        var objectType: UInt32 = 0
        if returned.commonattr & commonObjectType != 0 {
            objectType = field.loadUnaligned(as: UInt32.self)
            field += MemoryLayout<UInt32>.size
        }
        var crtime: Int64 = 0
        if returned.commonattr & commonCreationTime != 0 {
            crtime = Int64(field.loadUnaligned(as: timespec.self).tv_sec)
            field += MemoryLayout<timespec>.size
        }
        var mtime: Int64 = 0
        if returned.commonattr & commonModificationTime != 0 {
            mtime = Int64(field.loadUnaligned(as: timespec.self).tv_sec)
            field += MemoryLayout<timespec>.size
        }
        var size: Int64 = 0
        if returned.fileattr & fileTotalSize != 0 {
            size = field.loadUnaligned(as: Int64.self)
        }
        guard name.count > 0 else { return nil }
        return DirectoryItem(
            name: name, isDirectory: objectType == typeDirectory, isSymlink: objectType == typeSymlink,
            device: device, size: size, mtime: mtime, crtime: crtime)
    }

    private func readWithReaddir(fd: Int32, _ body: (DirectoryItem) -> Void) -> Int32 {
        let directoryFD = dup(fd)
        guard directoryFD >= 0, let directory = fdopendir(directoryFD) else {
            if directoryFD >= 0 { close(directoryFD) }
            return errno
        }
        defer { closedir(directory) }
        while let entry = readdir(directory) {
            let nameLength = Int(entry.pointee.d_namlen)
            withUnsafeBytes(of: &entry.pointee.d_name) { raw in
                let start = raw.baseAddress!
                let name = UnsafeBufferPointer(start: start.assumingMemoryBound(to: UInt8.self), count: nameLength)
                if nameLength == 1 && name[0] == UInt8(ascii: ".") { return }
                if nameLength == 2 && name[0] == UInt8(ascii: ".") && name[1] == UInt8(ascii: ".") { return }
                var info = stat()
                let found = fstatat(fd, start.assumingMemoryBound(to: CChar.self), &info, AT_SYMLINK_NOFOLLOW) == 0
                let type = Int32(info.st_mode) & Int32(S_IFMT)
                body(DirectoryItem(
                    name: name,
                    isDirectory: found ? type == Int32(S_IFDIR) : Int32(entry.pointee.d_type) == DT_DIR,
                    isSymlink: found ? type == Int32(S_IFLNK) : Int32(entry.pointee.d_type) == DT_LNK,
                    device: found ? info.st_dev : 0,
                    size: found && type == Int32(S_IFREG) ? info.st_size : 0,
                    mtime: found ? Int64(info.st_mtimespec.tv_sec) : 0,
                    crtime: found ? Int64(info.st_birthtimespec.tv_sec) : 0))
            }
        }
        return 0
    }
}
