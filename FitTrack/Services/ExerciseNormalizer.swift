import Foundation

enum ExerciseNormalizer {
    private static let abbreviations: [(String, String)] = [
        ("t2b", "toes to bar"),
        ("ttb", "toes to bar"),
        ("c2b", "chest to bar"),
        ("hspu", "handstand pushup"),
        ("bss", "bulgarian split squat"),
        ("rfe", "rear foot elevated"),
        ("rdl", "romanian deadlift"),
        ("ohp", "overhead press"),
        ("du", "double under"),
        ("ghd", "glute ham developer"),
        ("sl", "single leg"),
        ("bb", "barbell"),
        ("db", "dumbbell"),
        ("kb", "kettlebell"),
        ("mb", "medicine ball")
    ]

    static func normalize(_ raw: String) -> String {
        var s = raw.lowercased()
        let allowed = CharacterSet.alphanumerics.union(.whitespaces)
        s = String(s.unicodeScalars.map { allowed.contains($0) ? Character($0) : " " })
        let tokens = s.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        let expanded: [String] = tokens.map { tok in
            for (abbr, full) in abbreviations where tok == abbr { return full }
            return tok
        }
        return expanded.joined(separator: " ")
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
    }

    /// Token-set Jaro-Winkler. Splits both strings into sorted unique tokens,
    /// rejoins, then runs Jaro-Winkler on the resulting strings — robust to
    /// word reordering ("bench press barbell" vs "barbell bench press").
    static func similarity(_ a: String, _ b: String) -> Double {
        let na = normalize(a)
        let nb = normalize(b)
        if na == nb { return 1.0 }
        let sa = Set(na.split(separator: " ").map(String.init))
        let sb = Set(nb.split(separator: " ").map(String.init))
        let joinedA = sa.sorted().joined(separator: " ")
        let joinedB = sb.sorted().joined(separator: " ")
        return jaroWinkler(joinedA, joinedB)
    }

    // MARK: - Jaro-Winkler (inline, no deps)

    private static func jaroWinkler(_ s1: String, _ s2: String) -> Double {
        let j = jaro(s1, s2)
        if j < 0.7 { return j }
        let a = Array(s1)
        let b = Array(s2)
        var prefix = 0
        let maxPrefix = min(4, min(a.count, b.count))
        while prefix < maxPrefix && a[prefix] == b[prefix] { prefix += 1 }
        return j + Double(prefix) * 0.1 * (1.0 - j)
    }

    private static func jaro(_ s1: String, _ s2: String) -> Double {
        let a = Array(s1)
        let b = Array(s2)
        let la = a.count
        let lb = b.count
        if la == 0 && lb == 0 { return 1.0 }
        if la == 0 || lb == 0 { return 0.0 }

        let matchDistance = max(la, lb) / 2 - 1
        var aMatches = [Bool](repeating: false, count: la)
        var bMatches = [Bool](repeating: false, count: lb)
        var matches = 0

        for i in 0..<la {
            let start = max(0, i - matchDistance)
            let end = min(i + matchDistance + 1, lb)
            if start >= end { continue }
            for k in start..<end {
                if bMatches[k] { continue }
                if a[i] != b[k] { continue }
                aMatches[i] = true
                bMatches[k] = true
                matches += 1
                break
            }
        }
        if matches == 0 { return 0.0 }

        var k = 0
        var transpositions = 0
        for i in 0..<la {
            if !aMatches[i] { continue }
            while !bMatches[k] { k += 1 }
            if a[i] != b[k] { transpositions += 1 }
            k += 1
        }

        let m = Double(matches)
        let t = Double(transpositions / 2)
        return (m / Double(la) + m / Double(lb) + (m - t) / m) / 3.0
    }
}
