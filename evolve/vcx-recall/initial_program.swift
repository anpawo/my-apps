import Foundation

// EVOLVE-BLOCK-START
// BM25 recall of ERRORS rules sharing words with a prompt (VCX ErrorsRecall).
// Contract: same output as before for any prompt and rule list; no global or static mutable state.
enum Recall {
    static let stop: Set<String> = ["a", "an", "the", "of", "to", "in", "on", "and", "or", "is", "are", "be", "it", "its", "for", "with", "by", "from", "at", "as", "that", "this", "not", "never", "no", "his", "him", "he", "my", "me", "what", "when", "one"]

    static func words(_ text: String) -> [String] {
        text.lowercased().split { !($0.isASCII && ($0.isLetter || $0.isNumber)) }.filter { $0.count > 1 && !stop.contains(String($0)) }.map { String($0.prefix(6)) }
    }

    static func recall(_ prompt: String, texts: [String], limit: Int = 4, minimum: Double = 6) -> [String] {
        let rules = texts.map { (text: $0, words: words("- " + $0)) }, query = Set(words(prompt))
        guard !rules.isEmpty, !query.isEmpty else { return [] }
        let counts = rules.map { Dictionary($0.words.map { ($0, 1.0) }, uniquingKeysWith: +) }
        let n = Double(rules.count), average = Double(rules.map(\.words.count).reduce(0, +)) / n
        var frequency: [String: Double] = [:]
        for count in counts { for word in count.keys { frequency[word, default: 0] += 1 } }
        let scored = zip(rules, counts).map { rule, count -> (Double, String) in
            let length = Double(rule.words.count)
            let score = query.reduce(0.0) { total, word in
                guard let f = count[word], let df = frequency[word] else { return total }
                return total + log(1 + (n - df + 0.5) / (df + 0.5)) * f * 2.2 / (f + 1.2 * (0.25 + 0.75 * length / average))
            }
            return (score, rule.text)
        }
        return scored.filter { $0.0 >= minimum }.sorted { $0.0 > $1.0 }.prefix(limit).map(\.1)
    }
}
// EVOLVE-BLOCK-END
