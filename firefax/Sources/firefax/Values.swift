import Foundation

// Where a field value comes from, and what a literal is never allowed to be.
// refs (keychain com.mr.firefax) and files carry his stable or per-form secrets; a literal that is
// shaped and checksummed like an identity number is refused, so a secret never reaches argv or a log
// by being pasted inline.

let keychainService = "com.mr.firefax"

protocol SecretStore {
    func value(_ name: String) -> String?
    func names() -> [(name: String, length: Int)]
}

protocol FileReader {
    // A regular, non-symlink, 0600, one-line file under 256 bytes; its single line, trimmed.
    func read(_ path: String) throws -> String
}

struct ValueError: Error { let reason: String }

func resolve(_ v: Value, store: SecretStore, files: FileReader) throws -> String {
    switch v {
    case .literal(let s):
        if let shape = Shape.refused(s) {
            throw ValueError(reason: "a literal shaped like \(shape) must come from a ref or a file, not inline")
        }
        if s.contains("\n") || s.contains("\r") {
            throw ValueError(reason: "a newline in a single-line value (Return submits the form)")
        }
        return s
    case .ref(let name):
        guard let s = store.value(name) else { throw ValueError(reason: "no keychain ref '\(name)'") }
        return s
    case .file(let path):
        return try files.read(path)
    }
}

enum Shape {
    // The reason a literal is refused, or nil. Spaces are stripped first: a grouped number is one token.
    static func refused(_ raw: String) -> String? {
        let s = raw.replacingOccurrences(of: " ", with: "")
        guard !s.isEmpty else { return nil }
        if isIBAN(s) { return "an IBAN" }
        if s.allSatisfy(\.isNumber) {
            switch s.count {
            case 13: return "a 13-digit number (NIR / numéro fiscal)"
            case 15: return "a 15-digit number (NIR)"
            case 16 where luhn(s): return "a card number"
            case 14 where luhn(s): return "a SIRET"
            case 9 where luhn(s): return "a SIREN"
            default: return nil   // Luhn alone never refuses: one number in ten passes it
            }
        }
        return nil
    }

    static func isIBAN(_ s: String) -> Bool {
        guard s.count >= 15, s.count <= 34 else { return false }
        let up = s.uppercased()
        guard let first = up.first, let second = up.dropFirst().first,
              first.isLetter, second.isLetter else { return false }
        guard up.allSatisfy({ $0.isLetter || $0.isNumber }) else { return false }
        // Move the first four characters to the end, map letters to two digits, take mod 97.
        let rearranged = up.dropFirst(4) + up.prefix(4)
        var remainder = 0
        for ch in rearranged {
            let piece: String
            if ch.isNumber { piece = String(ch) }
            else { piece = String(Int(ch.asciiValue! - 65) + 10) }  // A=10 .. Z=35
            for d in piece { remainder = (remainder * 10 + Int(String(d))!) % 97 }
        }
        return remainder == 1
    }

    static func luhn(_ s: String) -> Bool {
        let digits = s.compactMap { $0.wholeNumberValue }
        guard digits.count == s.count, !digits.isEmpty else { return false }
        var sum = 0
        for (i, d) in digits.reversed().enumerated() {
            if i % 2 == 1 { let doubled = d * 2; sum += doubled > 9 ? doubled - 9 : doubled }
            else { sum += d }
        }
        return sum % 10 == 0
    }
}

// Live keychain, via the Security framework (no subprocess, so no value on any argv).
final class Keychain: SecretStore {
    func value(_ name: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: name,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func names() -> [(name: String, length: Int)] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let items = out as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let name = item[kSecAttrAccount as String] as? String else { return nil }
            let len = (item[kSecValueData as String] as? Data)?.count ?? 0
            return (name, len)
        }.sorted { $0.name < $1.name }
    }

    @discardableResult
    func store(_ name: String, _ data: Data) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: name,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = data
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
}

struct Files: FileReader {
    func read(_ path: String) throws -> String {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
        if values.isSymbolicLink == true { throw ValueError(reason: "value file is a symlink") }
        guard values.isRegularFile == true else { throw ValueError(reason: "value file is not a regular file") }
        guard (values.fileSize ?? .max) <= 256 else { throw ValueError(reason: "value file is over 256 bytes") }
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        if let perm = attrs[.posixPermissions] as? NSNumber, perm.intValue & 0o077 != 0 {
            throw ValueError(reason: "value file is not 0600")
        }
        let text = try String(contentsOf: url, encoding: .utf8)
        let lines = text.split(whereSeparator: \.isNewline)
        guard lines.count <= 1 else { throw ValueError(reason: "value file has more than one line") }
        return (lines.first.map(String.init) ?? "").trimmingCharacters(in: .whitespaces)
    }
}
