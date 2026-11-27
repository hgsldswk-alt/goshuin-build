import Foundation

struct Book: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
}

struct Place: Codable, Equatable {
    var latitude: Double
    var longitude: Double

    var isValid: Bool {
        latitude.isFinite && longitude.isFinite && (20...46).contains(latitude) && (122...154).contains(longitude)
    }
}

struct Temple: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var kana = ""
    var region = ""
    var address = ""
    var place: Place?
}

struct Crop: Codable, Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    var isValid: Bool {
        x >= 0 && y >= 0 && width >= 0.05 && height >= 0.05 && x + width <= 1.000001 && y + height <= 1.000001
    }
}

struct StampEntry: Codable, Identifiable, Equatable {
    enum Source: String, Codable { case camera, library, sample }
    var id = UUID()
    var bookID: UUID
    var assetID = UUID()
    var order: Int
    var addedAt = Date()
    var addedDay: String?
    var capturedAt: Date?
    var visitDay: String?
    var templeID: UUID?
    var crop: Crop?
    var deletedAt: Date?
    var revision = 0
    var source: Source
}

struct Station: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var region = ""
    var templeID: UUID?
    var visitedAt: Date?
}

struct Route: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var stations: [Station]

    var visited: Int { stations.lazy.filter { $0.visitedAt != nil }.count }
    var complete: Bool { !stations.isEmpty && visited == stations.count }
    var next: Station? { stations.first { $0.visitedAt == nil } }
}

struct Milestone: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case ten, fifty, route }
    var id: String
    var kind: Kind
    var routeID: UUID?

    var title: String { L.t("milestone." + kind.rawValue) }
}

struct Archive: Codable, Equatable {
    var books: [Book] = [Book(name: L.t("book.default"))]
    var entries: [StampEntry] = []
    var temples: [Temple] = []
    var routes: [Route] = []
    var currentRoute: UUID?
    var achieved: Set<String> = []
    var pending: [Milestone] = []
    var restoredPackages: Set<String> = []

    var active: [StampEntry] { entries.filter { $0.deletedAt == nil } }
    var canRequestRating: Bool {
        active.count >= 5 && Set(active.map { $0.addedDay ?? VisitDay.key($0.addedAt) }).count >= 3
    }

    func temple(_ id: UUID?) -> Temple? { temples.first { $0.id == id } }
    func name(for entry: StampEntry) -> String { temple(entry.templeID)?.name ?? L.t("temple.unset") }

    func filtered(book: UUID?, query: String, month: String?) -> [StampEntry] {
        let needle = Search.normalized(query)
        let names = needle.isEmpty ? [:] : Dictionary(uniqueKeysWithValues: temples.map { ($0.id, $0) })
        return active.filter { entry in
            let matchesMonth = month.map { key in
                key == "unknown" ? entry.visitDay == nil : entry.visitDay?.hasPrefix(key) == true
            } ?? true
            guard (book == nil || entry.bookID == book) && matchesMonth else { return false }
            if needle.isEmpty { return true }
            let place = entry.templeID.flatMap { names[$0] }
            return [place?.name ?? L.t("temple.unset"), place?.kana ?? "", place?.region ?? "", place?.address ?? ""]
                .contains { Search.normalized($0).contains(needle) }
        }.sorted { first, second in
            if first.visitDay != second.visitDay { return (first.visitDay ?? "") > (second.visitDay ?? "") }
            if first.order != second.order { return first.order > second.order }
            return first.addedAt > second.addedAt
        }
    }

    func paperOrder(_ entries: [StampEntry]) -> [StampEntry] {
        let bookOrder = Dictionary(uniqueKeysWithValues: books.enumerated().map { ($0.element.id, $0.offset) })
        return entries.sorted { first, second in
            if first.bookID != second.bookID {
                let firstBook = bookOrder[first.bookID] ?? Int.max
                let secondBook = bookOrder[second.bookID] ?? Int.max
                return firstBook == secondBook ? first.bookID.uuidString < second.bookID.uuidString : firstBook < secondBook
            }
            if first.order != second.order { return first.order > second.order }
            return first.id.uuidString < second.id.uuidString
        }
    }

    mutating func changeOrder(_ ids: [UUID], in book: UUID) {
        let keys = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($0.element, ids.count - $0.offset) })
        for index in entries.indices where entries[index].bookID == book {
            if let order = keys[entries[index].id], entries[index].order != order {
                entries[index].order = order
                entries[index].revision += 1
            }
        }
    }

    mutating func checkPageMilestones() {
        for (threshold, kind) in [(10, Milestone.Kind.ten), (50, .fifty)] where active.count >= threshold {
            award(Milestone(id: kind.rawValue, kind: kind))
        }
    }

    mutating func award(_ milestone: Milestone) {
        if achieved.insert(milestone.id).inserted { pending.append(milestone) }
    }

    mutating func toggle(route routeID: UUID, station stationID: UUID, now: Date = Date()) {
        guard let r = routes.firstIndex(where: { $0.id == routeID }),
              let s = routes[r].stations.firstIndex(where: { $0.id == stationID }) else { return }
        let visited = routes[r].stations[s].visitedAt != nil
        routes[r].stations[s].visitedAt = visited ? nil : now
        if routes[r].complete {
            award(Milestone(id: "route:" + routeID.uuidString, kind: .route, routeID: routeID))
        }
    }
}

enum Search {
    static func normalized(_ text: String) -> String {
        var value = text.folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "ja"))
        value = value.applyingTransform(.hiraganaToKatakana, reverse: true) ?? value
        for (old, new) in [("神", "神"), ("髙", "高"), ("﨑", "崎"), ("邊", "辺"), ("邉", "辺"), ("澤", "沢"), ("廣", "広")] {
            value = value.replacingOccurrences(of: old, with: new)
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum VisitDay {
    static func key(_ date: Date, zone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    static func date(_ key: String?) -> Date? {
        guard let key, key.count == 10 else { return nil }
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, let date = Calendar(identifier: .gregorian).date(
            from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12)),
            Self.key(date) == key else { return nil }
        return date
    }

    static func label(_ key: String?) -> String {
        date(key)?.formatted(date: .abbreviated, time: .omitted) ?? L.t("date.unknown")
    }

    static func monthLabel(_ key: String) -> String {
        date(key + "-01")?.formatted(.dateTime.year().month(.wide)) ?? key
    }
}

enum ArchiveError: String, LocalizedError {
    case badPhoto = "error.photo"
    case badRoute = "error.route"
    case duplicate = "error.duplicate"
    case duplicateStop = "error.duplicateStop"
    case badBackup = "error.backup"
    case tooLarge = "error.large"
    case lowSpace = "error.space"
    case stale = "error.stale"
    case missing = "error.missing"

    var errorDescription: String? { L.t(rawValue) }
}
