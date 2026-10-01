import Foundation

/// Turn-by-turn voice guidance, pure and offline, worded like a road GPS (Waze, Google Maps):
/// « Dans 1,5 kilomètre, tournez à droite sur la D5, direction Sault » (fast roads), « Dans 300 mètres, au rond-point,
/// prenez la deuxième sortie », « Tournez à droite, puis tournez à gauche », and after a maneuver
/// « Continuez sur la D943 pendant 12 kilomètres ». Instructions are stored in the trip (computed on the PC) and
/// positioned by distance along the day's track: no network, no AI while riding.
public enum TurnGuide {
    public struct Announcement: Equatable, Sendable {
        /// Unique per instruction and phase: the voice service says each key once.
        public let key: String
        public let text: String
        /// Camera, hazard, turn « maintenant »: said before (and cutting) traffic or weather messages.
        public let urgent: Bool

        public init(key: String, text: String, urgent: Bool = false) {
            self.key = key
            self.text = text
            self.urgent = urgent
        }
    }

    /// Depart, straight-on, via points and arrival are not turns (arrival has its own announcement).
    public static func isAnnounced(_ maneuver: Maneuver) -> Bool {
        ![.depart, .straight, .via, .arrive].contains(maneuver)
    }

    /// Next announced maneuver strictly ahead of `progress` (metres along the track).
    public static func next(_ instructions: [TurnInstruction], progress: Double)
        -> (index: Int, instruction: TurnInstruction, distance: Double)? {
        for (i, ins) in instructions.enumerated() where isAnnounced(ins.maneuver) && ins.along > progress {
            return (i, ins, ins.along - progress)
        }
        return nil
    }

    // MARK: Timing

    /// Lead distances for a speed in m/s: early warning about a minute ahead on fast roads (0.8–2 km), preparation
    /// about 18 s ahead (250–500 m), and the order itself about 4 s before the maneuver (25–90 m).
    public static func leads(speed: Double) -> (early: Double, prepare: Double, now: Double) {
        let v = max(0, speed.isFinite ? speed : 0)
        return (early: min(2_000, max(800, v * 60)), prepare: min(500, max(250, v * 18)), now: min(90, max(25, v * 4)))
    }

    /// Early warnings only above 50 km/h (in town, 300 m is enough).
    public static let earlySpeed = 50 / 3.6
    /// Two maneuvers closer than this are said together (« …, puis tournez à gauche »).
    public static let chainDistance = 150.0
    /// After a maneuver, a « continue » line when the next one is farther than this.
    public static let continueDistance = 2_000.0

    /// The announcement due at `progress`, if any (at most one per call; the voice service says each key once).
    public static func announcement(_ instructions: [TurnInstruction], progress: Double, speed: Double) -> Announcement? {
        let lead = leads(speed: speed)
        let next = self.next(instructions, progress: progress)

        // Arrival (« Dans 300 mètres, vous arrivez à destination »), when no turn comes before it.
        if let arrival = instructions.last, arrival.maneuver == .arrive, arrival.along > progress,
           next.map({ $0.instruction.along > arrival.along }) ?? true {
            let d = arrival.along - progress
            if d <= lead.prepare && d > lead.now {
                return Announcement(key: "arrive-soon", text: "\(spokenDistance(d)), vous arrivez à destination")
            }
        }

        if let n = next {
            let ins = n.instruction
            // Distance from the previous maneuver (none: as far as needed, the first turn gets its preparation).
            let previous = instructions[..<n.index].last { isAnnounced($0.maneuver) || $0.maneuver == .depart }?.along
            let gap = previous.map { ins.along - $0 } ?? .infinity
            if n.distance <= lead.now {
                var text = sentenceCase(phrase(ins, withRoad: ins.maneuver == .roundabout))
                if let then = instructions[(n.index + 1)...].first(where: { isAnnounced($0.maneuver) }),
                   then.along - ins.along <= chainDistance {
                    text += ", puis \(phrase(then, withRoad: false))"
                }
                return Announcement(key: "turn-\(n.index)-now", text: text, urgent: true)
            }
            if n.distance <= lead.prepare && gap > lead.now + 50 {
                return Announcement(key: "turn-\(n.index)-soon", text: "\(spokenDistance(n.distance)), \(phrase(ins, withRoad: true))")
            }
            if n.distance <= lead.early && speed >= earlySpeed && gap > lead.prepare + 300 {
                return Announcement(key: "turn-\(n.index)-early", text: "\(spokenDistance(n.distance)), \(phrase(ins, withRoad: true))")
            }
        }

        // Just after a maneuver, a long way to the next one: « Continuez sur la D943 pendant 12 kilomètres ».
        if let p = instructions.lastIndex(where: { ($0.maneuver == .depart || isAnnounced($0.maneuver)) && $0.along <= progress }) {
            let since = progress - instructions[p].along
            let ahead = (next?.instruction.along ?? instructions.last?.along ?? progress) - progress
            if since >= 30 && since <= 400 && ahead > continueDistance {
                let road = roadName(instructions[p])
                return Announcement(key: "continue-\(p)",
                                    text: "Continuez \(road.map { "sur \($0)" } ?? "tout droit") pendant \(spokenLength(ahead))")
            }
        }
        return nil
    }

    /// A direction (turn, « continuez », arrival soon), as opposed to an alert: silenced in « alertes uniquement ».
    /// Keys may carry a prefix (« detour- » for a route to a place or back to the track).
    public static func isDirection(_ a: Announcement) -> Bool {
        let key = a.key.hasPrefix("detour-") ? String(a.key.dropFirst("detour-".count)) : a.key
        return key.hasPrefix("turn-") || key.hasPrefix("continue-") || key == "arrive-soon"
    }

    // MARK: Wording

    /// What to do, lowercase, ready to follow « Dans 300 mètres, »: « tournez à droite sur la D5, direction Sault ».
    /// Structured data (maneuver, road, exit, direction) is preferred; otherwise the routing engine's text, cleaned.
    public static func phrase(_ ins: TurnInstruction, withRoad: Bool) -> String {
        let road = withRoad ? roadName(ins) : nil
        let toward = withRoad ? ins.toward.map(cleanDirection).flatMap { $0.isEmpty ? nil : $0 } : nil
        let structured = ins.street?.isEmpty == false || ins.ref?.isEmpty == false || ins.exit != nil || ins.toward != nil
        if !structured, !ins.text.isEmpty {
            return lowercasingFirst(cleanText(ins.text))
        }
        var s: String
        switch ins.maneuver {
        case .turnLeft: s = "tournez à gauche"
        case .turnRight: s = "tournez à droite"
        case .slightLeft: s = "tournez légèrement à gauche"
        case .slightRight: s = "tournez légèrement à droite"
        case .sharpLeft: s = "tournez fortement à gauche"
        case .sharpRight: s = "tournez fortement à droite"
        case .keepLeft: s = "restez à gauche"
        case .keepRight: s = "restez à droite"
        case .uTurn: s = "faites demi-tour"
        case .roundabout: s = ins.exit.map { "au rond-point, prenez la \(ordinal($0)) sortie" } ?? "au rond-point, continuez"
        case .depart, .straight, .via: s = "continuez tout droit"
        case .arrive: return "vous arrivez à destination"
        }
        if let road { s += " sur \(road)" }
        if let toward { s += ", direction \(toward)" }
        return s
    }

    /// Text for the banner: the full order with its road, capitalised.
    public static func banner(_ ins: TurnInstruction) -> String {
        sentenceCase(phrase(ins, withRoad: true))
    }

    /// « la D5 », « l'A7 », « Avenue Gambetta »: the road's name, else its number with its article.
    static func roadName(_ ins: TurnInstruction) -> String? {
        if let name = ins.street?.trimmingCharacters(in: .whitespaces), !name.isEmpty { return name }
        guard let ref = ins.ref?.trimmingCharacters(in: .whitespaces), !ref.isEmpty else { return nil }
        let compact = ref.split(separator: ";").first.map { $0.replacingOccurrences(of: " ", with: "") } ?? ref
        guard compact.range(of: #"^[A-Z]{1,3}\d+[A-Za-z]?$"#, options: .regularExpression) != nil else { return ref }
        return ("AEIOU".contains(compact.first!) ? "l'" : "la ") + compact
    }

    /// « Cadenet, [S 8] » → « Cadenet »; several destinations → the first two.
    static func cleanDirection(_ s: String) -> String {
        let noBrackets = s.replacingOccurrences(of: #"\[[^\]]*\]"#, with: "", options: .regularExpression)
        let parts = noBrackets.split(whereSeparator: { $0 == "," || $0 == ";" })
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return parts.prefix(2).joined(separator: " et ")
    }

    /// Routing-engine text made speakable: ordinals in words, no bracketed codes, « fort » → « fortement ».
    static func cleanText(_ text: String) -> String {
        var t = text.replacingOccurrences(of: #"\s*\[[^\]]*\]"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: " et conduisez vers ", with: ", direction ")
        t = t.replacingOccurrences(of: "fort à ", with: "fortement à ")
        if let r = t.range(of: #"\b(\d+)(e|re|er|ème)\b"#, options: .regularExpression),
           let n = Int(t[r].prefix { $0.isNumber }) {
            t.replaceSubrange(r, with: ordinal(n))
        }
        return t.trimmingCharacters(in: CharacterSet(charactersIn: " ,"))
    }

    static func ordinal(_ n: Int) -> String {
        let words = ["première", "deuxième", "troisième", "quatrième", "cinquième", "sixième", "septième", "huitième"]
        return (1...words.count).contains(n) ? words[n - 1] : "\(n)e"
    }

    // MARK: Distances

    /// « Dans 300 mètres » (rounded to 50 m) or « Dans 1,5 kilomètre ».
    public static func spokenDistance(_ metres: Double) -> String {
        "Dans \(spokenLength(metres))"
    }

    /// « 300 mètres », « 1,5 kilomètre », « 12 kilomètres » (whole km beyond 5 km).
    public static func spokenLength(_ metres: Double) -> String {
        if metres < 950 {
            let rounded = max(50, Int((metres / 50).rounded()) * 50)
            return "\(rounded) mètres"
        }
        let km = metres >= 5_000 ? (metres / 1000).rounded() : (metres / 100).rounded() / 10
        let value = km == km.rounded() ? String(Int(km)) : String(format: "%.1f", km).replacingOccurrences(of: ".", with: ",")
        return "\(value) kilomètre\(km >= 2 ? "s" : "")"
    }

    public static func lowercasingFirst(_ s: String) -> String {
        guard let first = s.first else { return s }
        return first.lowercased() + s.dropFirst()
    }

    static func sentenceCase(_ s: String) -> String {
        guard let first = s.first else { return s }
        return first.uppercased() + s.dropFirst()
    }
}
