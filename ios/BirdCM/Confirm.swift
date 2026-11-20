import Foundation

/// Mirrors committed engine/birdcm/tower.py + confirm.py (impl efec7db, 2026-11-18). No family fallback.
enum Confirm {
    static let speciesP = 0.94, genusP = 0.94, eps = 0.01, tau = 0.05
    static func posterior(_ visual: [Double], _ geo: [Double]?) -> [Double] {
        guard let geo else { return visual }
        precondition(geo.count == visual.count)
        let p = zip(visual, geo).map { $0 * (0.02 + ($1.isNaN ? 0.05 : $1)) }, sum = p.reduce(0,+)
        return sum > 0 ? p.map { $0 / sum } : visual
    }
    static func decide(p: [Double], rows: [[String]], wide: [Double]?, typical: [Double]?) -> Identification {
        let top = Array(p.indices.sorted { p[$0] > p[$1] }.prefix(5))
        let c = top.map { Candidate(scientific: rows[$0][0], english: rows[$0][1], chinese: rows[$0][2], p: p[$0]) }
        var mass: [String: Double] = [:]
        for i in p.indices { mass[rows[i][3], default: 0] += p[i] }
        let genus = mass.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.first!
        var level = c[0].p >= speciesP ? "species" : genus.value >= genusP ? "genus" : "uncertain"
        var reason: String?, rare = false
        var priorUnknown: Bool?
        if let wide, let typical {
            if wide[top[0]].isNaN {
                priorUnknown = true
            } else if wide[top[0]] < eps {
                reason = String(localized: "图像最像 \(c[0].chinese.isEmpty ? c[0].english : c[0].chinese)，但此地此季几乎没有它。")
                if let j = top.dropFirst().first(where: { rows[$0][3] == rows[top[0]][3] && wide[$0] >= tau }) {
                    reason! += String(localized: "当地同属候选：\(rows[j][2].isEmpty ? rows[j][1] : rows[j][2])。")
                }
                if level == "species" { level = genus.value >= genusP ? "genus" : "uncertain" }
            } else if level == "species" && typical[top[0]] < tau { rare = true }
        }
        return Identification(top5: c, level: level, name: level == "species" ? c[0].scientific : level == "genus" ? genus.key : nil,
                              rare: rare, reason: reason, genusP: genus.value, priorUnknown:priorUnknown)
    }
}
