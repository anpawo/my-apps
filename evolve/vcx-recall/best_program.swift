import Foundation

// EVOLVE-BLOCK-START
// BM25 recall of ERRORS rules sharing words with a prompt (VCX ErrorsRecall).
// Contract: same output as before for any prompt and rule list; no global or static mutable state.
enum Recall {
    static let stop: Set<String> = ["a", "an", "the", "of", "to", "in", "on", "and", "or", "is", "are", "be", "it", "its", "for", "with", "by", "from", "at", "as", "that", "this", "not", "never", "no", "his", "him", "he", "my", "me", "what", "when", "one"]

    static func words(_ text: String) -> [String] {
        text.lowercased().split { !($0.isASCII && ($0.isLetter || $0.isNumber)) }.filter { $0.count > 1 && !stop.contains(String($0)) }.map { String($0.prefix(6)) }
    }

    private static let prefixLength = 6
    private static let appendLimit = UInt64(1) << (8 * (prefixLength - 1))
    private static let stopKeys = Set(stop.map { pack($0) })
    private static let stopKeyLimit = UInt64(1) << (8 * (stop.map { $0.utf8.count }.max() ?? 0))
    private static let maximumInsertionLimit = 8
    private static let queryTableBits = 8
    private static let collisionKey = UInt64.max
    private static let queryKeyBits = prefixLength * UInt8.bitWidth
    private static let queryKeyMask = (UInt64(1) << queryKeyBits) - 1
    private static let packedTermLimit = UInt64(1) << (UInt64.bitWidth - queryKeyBits)

    private static let lowercaseBytes: [UInt8] = (0...Int(UInt8.max)).map { value in
        let byte = UInt8(value)
        let lower = byte | 32
        return lower &- 97 < 26 || byte &- 48 < 10 ? lower : 0
    }

    private static let stopTableBits = 8
    private static let stopTable: [UInt64] = {
        var table = [UInt64](repeating: 0, count: 1 << stopTableBits)
        for key in stopKeys where key > UInt8.max {
            let slot = stopSlot(key)
            table[slot] = table[slot] == 0 ? key : collisionKey
        }
        return table
    }()

    @inline(__always)
    private static func stopSlot(_ key: UInt64) -> Int {
        let mixed = (key ^ (key >> 13)) &* 0x9E37_79B9_7F4A_7C15
        return Int(mixed >> (UInt64.bitWidth - stopTableBits))
    }

    @inline(__always)
    private static func isStop(_ key: UInt64) -> Bool {
        let entry = stopTable[stopSlot(key)]
        return entry == key || (entry == collisionKey && stopKeys.contains(key))
    }

    private static func pack<S: StringProtocol>(_ word: S) -> UInt64 {
        word.utf8.prefix(prefixLength).reduce(0) { ($0 << 8) | UInt64($1) }
    }

    @inline(__always)
    private static func querySlot(_ key: UInt64) -> Int {
        let mixed = (key ^ (key >> 24)) &* 0x9E37_79B9_7F4A_7C15
        return Int(mixed >> (UInt64.bitWidth - queryTableBits))
    }

    private static func canScanBytes(_ bytes: UnsafeBufferPointer<UInt8>) -> Bool {
        let raw = UnsafeRawBufferPointer(bytes)
        let wordSize = MemoryLayout<UInt64>.size
        let highBits: UInt64 = 0x8080_8080_8080_8080
        var offset = 0
        while offset < bytes.count {
            if offset <= bytes.count - wordSize {
                let word = UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt64.self))
                let nonASCII = word & highBits
                if nonASCII == 0 {
                    offset += wordSize
                    continue
                }
                offset += nonASCII.trailingZeroBitCount / UInt8.bitWidth
            } else if bytes[offset] < 0x80 {
                offset += 1
                continue
            }

            // These scalars stay separators after lowercasing and cannot extend an ASCII grapheme.
            let remaining = bytes.count - offset
            guard remaining >= 2 else { return false }
            switch (bytes[offset], bytes[offset + 1]) {
            case (0xC2, 0xA0), (0xC3, 0x80...0xBF):
                offset += 2
            case (0xE2, 0x80):
                guard remaining >= 3 else { return false }
                switch bytes[offset + 2] {
                case 0x90...0x9F, 0xA2, 0xA6:
                    offset += 3
                default:
                    return false
                }
            case (0xE2, 0x86):
                guard remaining >= 3, bytes[offset + 2] == 0x92 else { return false }
                offset += 3
            default:
                return false
            }
        }
        return true
    }

    private static func scanRule(_ text: String, emit: (UInt64) -> Void) {
        let scanned = text.utf8.withContiguousStorageIfAvailable { bytes -> Bool in
            guard canScanBytes(bytes) else { return false }

            lowercaseBytes.withUnsafeBufferPointer { lowercase in
                var key: UInt64 = 0
                for byte in bytes {
                    let lower = lowercase[Int(byte)]
                    if lower != 0 {
                        if key < appendLimit {
                            key = (key << 8) | UInt64(lower)
                        }
                    } else {
                        if key > UInt8.max && (key >= stopKeyLimit || !isStop(key)) {
                            emit(key)
                        }
                        key = 0
                    }
                }
                if key > UInt8.max && (key >= stopKeyLimit || !isStop(key)) {
                    emit(key)
                }
            }
            return true
        } ?? false

        if !scanned {
            let tokens = ("- " + text).lowercased().split {
                !($0.isASCII && ($0.isLetter || $0.isNumber))
            }
            for token in tokens {
                let key = pack(token)
                if key > UInt8.max && (key >= stopKeyLimit || !stopKeys.contains(key)) {
                    emit(key)
                }
            }
        }
    }

    static func recall(_ prompt: String, texts: [String], limit: Int = 4, minimum: Double = 6) -> [String] {
        guard !texts.isEmpty, limit != 0 else { return [] }
        let query = Set(words(prompt))
        guard !query.isEmpty else { return [] }

        var queryTable = [UInt64](repeating: 0, count: 1 << queryTableBits)
        var collisions: [UInt64: Int] = [:]
        for (index, word) in query.enumerated() {
            let key = pack(word)
            let slot = querySlot(key)
            let entry = queryTable[slot]
            if entry == 0 && UInt64(index) < packedTermLimit {
                queryTable[slot] = key | (UInt64(index) << queryKeyBits)
                continue
            }
            if entry != 0 && entry != collisionKey {
                collisions[entry & queryKeyMask] = Int(entry >> queryKeyBits)
            }
            queryTable[slot] = collisionKey
            collisions[key] = index
        }

        var postings = [[(rule: Int, count: Double)]](repeating: [], count: query.count)
        var lengths = [Int](repeating: 0, count: texts.count)
        var totalLength = 0
        for (rule, text) in texts.enumerated() {
            var length = 0
            scanRule(text) { key in
                length += 1
                let entry = queryTable[querySlot(key)]
                let term: Int
                if entry & queryKeyMask == key {
                    term = Int(entry >> queryKeyBits)
                } else {
                    guard entry == collisionKey, let match = collisions[key] else { return }
                    term = match
                }
                let last = postings[term].count - 1
                if last >= 0 && postings[term][last].rule == rule {
                    postings[term][last].count += 1
                } else {
                    postings[term].append((rule, 1))
                }
            }
            lengths[rule] = length
            totalLength += length
        }

        guard postings.contains(where: { !$0.isEmpty }) else {
            let eligible = 0.0 >= minimum ? texts[...] : texts.prefix(0)
            return Array(eligible.prefix(limit))
        }

        let n = Double(texts.count)
        let average = Double(totalLength) / n
        let norms = lengths.map { 1.2 * (0.25 + 0.75 * Double($0) / average) }
        var scores = [Double](repeating: 0, count: texts.count)
        for matches in postings where !matches.isEmpty {
            let df = Double(matches.count)
            let idf = log(1 + (n - df + 0.5) / (df + 0.5))
            for (rule, f) in matches {
                scores[rule] += idf * f * 2.2 / (f + norms[rule])
            }
        }

        return ranked(scores, limit: limit, minimum: minimum).map { texts[$0] }
    }

    private static func ranked(_ scores: [Double], limit: Int, minimum: Double) -> [Int] {
        guard (1...maximumInsertionLimit).contains(limit) else {
            return Array(scores.indices.filter { scores[$0] >= minimum }
                .sorted { scores[$0] > scores[$1] }.prefix(limit))
        }

        var best: [Int] = []
        best.reserveCapacity(limit)
        for rule in scores.indices {
            let score = scores[rule]
            guard score >= minimum else { continue }
            if best.count == limit {
                guard score > scores[best[best.count - 1]] else { continue }
                best.removeLast()
            }
            let position = best.firstIndex { score > scores[$0] } ?? best.count
            best.insert(rule, at: position)
        }
        return best
    }
}
// EVOLVE-BLOCK-END
