// SuperAudio © 2026 David Puerto. Proprietary — see LICENSE.md.

import Foundation

/// HomeKit / AirPlay 2 **TLV8** type-length-value encoding — the message
/// grammar carried in the body of `/pair-setup` and `/pair-verify` POSTs.
///
/// Wire format (a fact, not copyrightable — implemented fresh, same stance as
/// our RAOP code; shairport-sync `pair_ap/` read only as reference):
///
///   [1 byte type][1 byte length 0–255][length bytes value] …
///
/// Two rules make it more than a flat list:
///   1. **Fragmentation.** A value longer than 255 bytes is split into
///      consecutive items of the *same type*, each ≤255 bytes. A fragment of
///      exactly 255 bytes means "more of this value follows." On decode,
///      consecutive same-type items are concatenated back into one value.
///   2. **Separators.** To send two *distinct* items that happen to share a
///      type, a zero-length separator (`0xFF`) is placed between them so the
///      concatenation rule doesn't merge them. (We don't emit repeated types,
///      so we never need to write separators — but decode honors them.)
public enum TLV8 {

    /// HomeKit pairing TLV types (the subset AirPlay 2 pairing uses).
    public enum Tag: UInt8 {
        case method        = 0x00
        case identifier    = 0x01
        case salt          = 0x02
        case publicKey     = 0x03
        case proof         = 0x04
        case encryptedData = 0x05
        case state         = 0x06
        case error         = 0x07
        case retryDelay    = 0x08
        case certificate   = 0x09
        case signature     = 0x0A
        case permissions   = 0x0B
        case fragmentData  = 0x0C
        case fragmentLast  = 0x0D
        case flags         = 0x13
        case separator     = 0xFF
    }

    /// HomeKit pairing error codes carried in a `.error` TLV.
    public enum PairingError: UInt8 {
        case unknown        = 0x01
        case authentication = 0x02   // bad SRP proof / setup code
        case backoff        = 0x03   // too many attempts; honor retryDelay
        case maxPeers       = 0x04
        case maxTries       = 0x05
        case unavailable    = 0x06
        case busy           = 0x07
    }

    public struct Item: Equatable {
        public let type: UInt8
        public let value: Data
        public init(type: UInt8, value: Data) {
            self.type = type
            self.value = value
        }
        public init(_ tag: Tag, _ value: Data) {
            self.init(type: tag.rawValue, value: value)
        }
        /// Single-byte convenience (state, method, flags, error…).
        public init(_ tag: Tag, byte: UInt8) {
            self.init(type: tag.rawValue, value: Data([byte]))
        }
    }

    // MARK: - Encode

    /// Serialize items in order, fragmenting any value > 255 bytes into
    /// consecutive same-type chunks per the spec.
    public static func encode(_ items: [Item]) -> Data {
        var out = Data()
        for item in items {
            let bytes = item.value
            if bytes.isEmpty {
                out.append(item.type)
                out.append(0)
                continue
            }
            var offset = bytes.startIndex
            while offset < bytes.endIndex {
                let chunkLen = Swift.min(255, bytes.distance(from: offset, to: bytes.endIndex))
                let end = bytes.index(offset, offsetBy: chunkLen)
                out.append(item.type)
                out.append(UInt8(chunkLen))
                out.append(bytes[offset..<end])
                offset = end
            }
        }
        return out
    }

    /// Convenience for the common "list of tag/value pairs" call site.
    public static func encode(_ pairs: [(Tag, Data)]) -> Data {
        encode(pairs.map { Item($0.0, $0.1) })
    }

    // MARK: - Decode

    /// Parse the byte stream into items, concatenating consecutive same-type
    /// fragments back into single values. Malformed trailing bytes (a length
    /// that overruns the buffer) are dropped rather than throwing — receivers
    /// occasionally pad, and a partial tail should not sink a valid message.
    public static func decode(_ data: Data) -> [Item] {
        var items: [Item] = []
        // Index into a contiguous copy so arithmetic is simple/0-based.
        let bytes = [UInt8](data)
        var i = 0
        var lastType: UInt8? = nil
        while i + 2 <= bytes.count {
            let type = bytes[i]
            let len = Int(bytes[i + 1])
            let valueStart = i + 2
            let valueEnd = valueStart + len
            guard valueEnd <= bytes.count else { break }   // overrun → stop
            let value = Data(bytes[valueStart..<valueEnd])
            if type == lastType, var prev = items.last, type != Tag.separator.rawValue {
                // Concatenate fragment onto the previous same-type item.
                prev = Item(type: type, value: prev.value + value)
                items[items.count - 1] = prev
            } else {
                items.append(Item(type: type, value: value))
            }
            lastType = type
            i = valueEnd
        }
        return items
    }

    // MARK: - Lookup

    /// First value for a tag (nil if absent). Pairing messages never carry
    /// two distinct items of the same pairing tag, so "first" is "the value."
    public static func value(_ tag: Tag, in items: [Item]) -> Data? {
        items.first { $0.type == tag.rawValue }?.value
    }

    /// First single-byte value for a tag (state, error, method…).
    public static func byte(_ tag: Tag, in items: [Item]) -> UInt8? {
        value(tag, in: items)?.first
    }
}
