import Foundation

struct RoadmapGroup: Identifiable {
    var id: String
    var title: String
    var steps: [RoadmapStep]
    var doneCount: Int { steps.filter(\.isDone).count }
    var isDone: Bool { !steps.isEmpty && steps.allSatisfy(\.isDone) }
}

enum RoadmapGrouping {
    static func groups(_ snapshot: RoadmapSnapshot) -> [RoadmapGroup] {
        var result: [RoadmapGroup] = []
        for step in snapshot.steps {
            let publication = snapshot.project.kind == .publication
            let relative = step.source.path.replacingOccurrences(of: snapshot.project.root.path + "/", with: "")
            let project = relative.components(separatedBy: "/").first ?? "Publication plan"
            let title = publication ? project + (step.group.isEmpty ? "" : " · " + step.group) : step.group
            let key = title.isEmpty ? step.id : (publication ? step.source.path + "#" : "") + title
            if let index = result.firstIndex(where: { $0.id == key }) {
                result[index].steps.append(step)
            } else {
                result.append(RoadmapGroup(id: key, title: title.isEmpty ? step.title : title, steps: [step]))
            }
        }
        return result
    }

    static func progressGroup(_ text: String) -> String {
        let subject = String(text.prefix(progressSubjectLimit))
        let themes = [
            ("Broker communication", #"\b(mail|email|e-mail|draft|inbox|outbox|notification|message|courriel|brouillon)\b"#),
            ("Dashboard and reporting", #"\b(dashboard|page|view|filter|interface|screen|report|reporting|rapport|affichage|filtre|filtres|UI)\b"#),
            ("Operations and automation", #"\b(routine|launchd|cron|schedule|automation|automatisation|quotidien|production|deploy|deployment)\b"#),
            ("Validation and reliability", #"\b(test|tests|mutant|mutants|audit|replay|rejeu|benchmark|security|regression)\b"#),
            ("Data ingestion", #"\b(ingest|ingestion|import|parser|parsing|ledger|cache|file|files|fichier|fichiers|données)\b"#),
            ("Reconciliation and matching", #"\b(recon|reconciliation|reconcile|match|matching|break|breaks|trade|trades|swap|swaps|settlement|V1|V3)\b"#),
        ]
        return themes.first { subject.range(of: $0.1, options: [.regularExpression, .caseInsensitive]) != nil }?.0 ?? "Other progress"
    }

    static func codes(in text: String, among codes: [String]) -> Set<String> {
        let value = text.replacingOccurrences(of: "\u{2013}", with: "-").replacingOccurrences(of: "\u{2014}", with: "-")
        var result = Set(codes.filter { code in
            value.range(of: #"\b"# + NSRegularExpression.escapedPattern(for: code) + #"\b"#, options: .regularExpression) != nil
        })
        let pattern = #"\b([A-Z])([0-9]+)\s*-\s*([A-Z]?)([0-9]+)\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return result }
        for match in regex.matches(in: value, range: NSRange(value.startIndex..., in: value)) {
            let pieces = (1...4).map { Range(match.range(at: $0), in: value).map { String(value[$0]) } ?? "" }
            guard let start = Int(pieces[1]), let end = Int(pieces[3]), start <= end,
                  pieces[2].isEmpty || pieces[2] == pieces[0] else { continue }
            result.formUnion(codes.filter { code in
                guard code.hasPrefix(pieces[0]), let number = Int(code.dropFirst()) else { return false }
                return start...end ~= number
            })
        }
        return result
    }

    private static let progressSubjectLimit = 160
}
