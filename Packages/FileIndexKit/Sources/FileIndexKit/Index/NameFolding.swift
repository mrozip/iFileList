import Foundation

/// Case- and diacritic-insensitive matching of file names.
///
/// ASCII names are compared in place with an ASCII lowercase. Non-ASCII names get a folded key
/// (lowercased, accents and width variants removed, NFC) that is compared the same way.
public enum NameFolding {
    @inline(__always)
    static func lowercaseASCII(_ byte: UInt8) -> UInt8 {
        (byte &- 65) < 26 ? byte | 0x20 : byte
    }

    static func isASCII(_ bytes: UnsafeBufferPointer<UInt8>) -> Bool {
        for byte in bytes where byte >= 0x80 { return false }
        return true
    }

    public static func fold(_ string: String) -> String {
        string.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .precomposedStringWithCanonicalMapping
    }

    /// The folded search key of a non-ASCII name, or nil when the name is ASCII and matched in place.
    static func foldedKey(_ name: UnsafeBufferPointer<UInt8>) -> [UInt8]? {
        guard !isASCII(name) else { return nil }
        let key = Array(fold(String(decoding: name, as: UTF8.self)).utf8)
        return key.isEmpty ? nil : key
    }

    /// Splits a query into whitespace-separated terms, folded like names.
    public static func terms(of query: String) -> [[UInt8]] {
        query.split(whereSeparator: \.isWhitespace).map { term in
            let utf8 = Array(term.utf8)
            let folded = utf8.allSatisfy({ $0 < 0x80 }) ? utf8 : Array(fold(String(term)).utf8)
            return folded.map(lowercaseASCII)
        }
    }

    /// Orders two search keys by their ASCII-lowercased bytes.
    static func compare(_ a: UnsafeBufferPointer<UInt8>, _ b: UnsafeBufferPointer<UInt8>) -> Int {
        let count = min(a.count, b.count)
        for i in 0..<count {
            let x = lowercaseASCII(a[i]), y = lowercaseASCII(b[i])
            if x != y { return x < y ? -1 : 1 }
        }
        return a.count == b.count ? 0 : (a.count < b.count ? -1 : 1)
    }

    /// The first eight lowercased key bytes packed big-endian, for a fast first sorting pass.
    static func sortPrefix(_ key: UnsafeBufferPointer<UInt8>) -> UInt64 {
        var prefix: UInt64 = 0
        for i in 0..<8 {
            prefix <<= 8
            if i < key.count { prefix |= UInt64(lowercaseASCII(key[i])) }
        }
        return prefix
    }
}
