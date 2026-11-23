import Foundation

// EVOLVE-BLOCK-START
// Fleet TranscriptStore cold read: before parsing the tail of a Claude transcript, the head of the file
// (often megabytes) is scanned for the few lines that start or end a background shell or an agent.
// Contract: return exactly the lines (split on "\n", empty lines dropped) that contain any mark, in file order.
// No global or static mutable state, no caches between calls, no threads.
enum Delegation {
    static let marks = ["background with ID", "moved to the background",
                        "Workflow launched in background", "<task-notification>",
                        "Successfully stopped task",
                        #""name":"Agent""#, #""name":"Task""#,
                        "Async agent launched", "resumedAgentId",
                        #""toolUseResult":{"status":"completed""#].map { Data($0.utf8) }

    static func lines(in head: Data) -> [Data] {
        let gramWidth = MemoryLayout<UInt32>.size
        let minimumWidth = 13 // Byte count of the shortest mark, `"name":"Task"`.
        guard head.count >= minimumWidth else { return [] }

        let stride = minimumWidth - gramWidth + 1
        let bucketBits = 16
        let hashMultiplier: UInt32 = 0x9E37_79B1
        let newline = UInt8(ascii: "\n")
        let batchSize = 8
        let reverseWidth = MemoryLayout<UInt64>.size
        let byteOnes: UInt64 = 0x0101_0101_0101_0101
        let byteHighBits: UInt64 = 0x8080_8080_8080_8080
        let newlineWord = UInt64(newline) * byteOnes

        @inline(__always)
        func bucket(_ gram: UInt32) -> Int {
            Int((gram &* hashMultiplier) >> (UInt32.bitWidth - bucketBits))
        }

        var buckets = [UInt8](repeating: 0, count: 1 << bucketBits)
        var candidates: [(suffix: UInt64, gram: UInt32, back: UInt8, width: UInt8, mark: UInt8, next: UInt8)] = []
        candidates.reserveCapacity(marks.count * stride)

        // The suffix contains a four-byte window at every sampling phase.
        for (markIndex, mark) in marks.enumerated() {
            mark.withUnsafeBytes { (needle: UnsafeRawBufferPointer) in
                let first = needle.count - minimumWidth
                let suffix = needle.loadUnaligned(fromByteOffset: needle.count - reverseWidth, as: UInt64.self)
                let width = UInt8(needle.count)
                let mark = UInt8(markIndex)
                for back in first..<(first + stride) {
                    let gram = needle.loadUnaligned(fromByteOffset: back, as: UInt32.self)
                    let key = bucket(gram)
                    candidates.append((suffix, gram, UInt8(back), width, mark, buckets[key]))
                    buckets[key] = UInt8(candidates.count)
                }
            }
        }

        return head.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> [Data] in
            let base = raw.baseAddress!
            let lastSample = raw.count - gramWidth
            let batchAdvance = batchSize * stride
            let lastBatch = lastSample - batchAdvance
            let halfBatchAdvance = batchAdvance / 2

            return buckets.withUnsafeBufferPointer { entries in
                let lookup = entries.baseAddress!

                @inline(__always)
                func probe(_ offset: Int) -> UInt8 {
                    lookup[bucket(base.loadUnaligned(fromByteOffset: offset, as: UInt32.self))]
                }

                var result: [Data] = []
                var lineFloor = 0
                var sample = stride - 1

                scan: while sample <= lastSample {
                    var entry: UInt8
                    while true {
                        if sample > lastBatch {
                            entry = probe(sample)
                            break
                        }

                        var first = probe(sample)
                        var second = probe(sample &+ stride)
                        var third = probe(sample &+ (2 * stride))
                        var fourth = probe(sample &+ (3 * stride))
                        let fifth = probe(sample &+ halfBatchAdvance)
                        let sixth = probe(sample &+ (halfBatchAdvance + stride))
                        let seventh = probe(sample &+ (halfBatchAdvance + 2 * stride))
                        let eighth = probe(sample &+ (halfBatchAdvance + 3 * stride))
                        let lower = first | second | third | fourth
                        if (lower | fifth | sixth | seventh | eighth) == 0 {
                            sample &+= batchAdvance
                            continue
                        }
                        if lower == 0 {
                            sample &+= halfBatchAdvance
                            first = fifth
                            second = sixth
                            third = seventh
                            fourth = eighth
                        }

                        if first != 0 {
                            entry = first
                        } else if second != 0 {
                            sample &+= stride
                            entry = second
                        } else if third != 0 {
                            sample &+= 2 * stride
                            entry = third
                        } else {
                            sample &+= 3 * stride
                            entry = fourth
                        }
                        break
                    }

                    if entry != 0 {
                        let gram = base.loadUnaligned(fromByteOffset: sample, as: UInt32.self)
                        while entry != 0 {
                            let candidate = candidates[Int(entry) - 1]
                            entry = candidate.next
                            guard candidate.gram == gram else { continue }

                            let offset = sample - Int(candidate.back)
                            let width = Int(candidate.width)
                            guard offset >= lineFloor, width <= raw.count - offset else { continue }

                            let matchEnd = offset + width
                            let suffix = base.loadUnaligned(fromByteOffset: matchEnd - reverseWidth, as: UInt64.self)
                            guard suffix == candidate.suffix else { continue }

                            let matches = marks[Int(candidate.mark)].withUnsafeBytes { (needle: UnsafeRawBufferPointer) in
                                memcmp(base + offset, needle.baseAddress!, width - reverseWidth) == 0
                            }
                            guard matches else { continue }

                            var start = offset
                            while start - lineFloor >= reverseWidth {
                                let word = base.loadUnaligned(fromByteOffset: start - reverseWidth, as: UInt64.self)
                                let bytes = word ^ newlineWord
                                if ((bytes &- byteOnes) & ~bytes & byteHighBits) != 0 { break }
                                start -= reverseWidth
                            }
                            while start > lineFloor && base.load(fromByteOffset: start - 1, as: UInt8.self) != newline {
                                start -= 1
                            }

                            let delimiter = memchr(base + matchEnd, Int32(newline), raw.count - matchEnd)
                            let end = delimiter.map { base.distance(to: UnsafeRawPointer($0)) } ?? raw.count
                            result.append(Data(bytes: base + start, count: end - start))
                            if raw.count - end <= minimumWidth { break scan }

                            lineFloor = end + 1
                            sample = lineFloor + stride - 1
                            continue scan
                        }
                    }

                    if lastSample - sample < stride { break }
                    sample += stride
                }

                return result
            }
        }
    }
}
// EVOLVE-BLOCK-END
