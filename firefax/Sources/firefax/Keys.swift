import Foundation

// Every keyboard event firefax posts carries this stamp in eventSourceUserData; autocorrect's tap
// passes a stamped event through untouched, so a key firefax sends into Firefox is never rewritten.
// Keep this value equal to firefaxEventStamp in autocorrect/Sources/autocorrect/Tap.swift.
let firefaxEventStamp: Int64 = 0x6669_7265_6661_78  // "firefax"

// Human typing cadence from Dhakal (CHI 2018, 136M keystrokes): gaps right-skewed, mean ~239 ms,
// SD ~112, never below ~60 ms; hold ~116 ms. A pure, seeded function so the selftest asserts its
// bounds without any real sleep.
enum Cadence {
    static func gaps(_ count: Int, seed: UInt64) -> [Double] {
        var rng = SplitMix(seed)
        return (0..<count).map { _ in
            // shifted log-normal: 60 ms floor plus a right-skewed body tuned to the Dhakal moments.
            (60 + exp(4.95 + 0.6 * rng.normal())).rounded()
        }
    }

    static func hold(seed: UInt64) -> Double {
        var rng = SplitMix(seed)
        return max(40, (116 + 24 * rng.normal()).rounded())
    }
}

struct SplitMix {
    private var state: UInt64
    init(_ seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func uniform() -> Double { Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0) }
    mutating func normal() -> Double {
        let u1 = max(uniform(), 1e-12), u2 = uniform()
        return (-2 * log(u1)).squareRoot() * cos(2 * Double.pi * u2)
    }
}

// U.S. ANSI layout: a character to its keycode and whether Shift is set (as an event flag, never a
// held key). Only letters, digits, space and the punctuation of names and addresses; anything else
// falls back to a Unicode-string event in the live typist.
enum USKeys {
    static func code(_ c: Character) -> (code: UInt16, shift: Bool)? {
        if let lower = c.lowercased().first, let base = letters[lower] {
            return (base, c.isUppercase)
        }
        return others[c]
    }

    private static let letters: [Character: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "o": 31, "u": 32,
        "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
    ]
    private static let others: [Character: (UInt16, Bool)] = [
        "1": (18, false), "2": (19, false), "3": (20, false), "4": (21, false), "5": (23, false),
        "6": (22, false), "7": (26, false), "8": (28, false), "9": (25, false), "0": (29, false),
        " ": (49, false), "-": (27, false), "'": (39, false), ".": (47, false), ",": (43, false), "/": (44, false),
    ]
}
