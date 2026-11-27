import Foundation

struct PublicRoute: Codable, Equatable {
    struct Stop: Codable, Equatable {
        var name: String
        var region: String
    }

    var version = 1
    var name: String
    var stations: [Stop]

    init(_ route: Route) {
        name = route.name
        stations = route.stations.map { Stop(name: $0.name, region: $0.region) }
    }

    init(name: String, stations: [Stop]) {
        self.name = name
        self.stations = stations
    }

    static let maxBytes = 96_000

    private static func clean(_ text: String, allowEmpty: Bool = false) throws -> String {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (allowEmpty || !value.isEmpty), value.count <= 100, value.utf8.count <= 400,
              value.unicodeScalars.allSatisfy({ !$0.properties.isBidiControl && !CharacterSet.controlCharacters.contains($0) })
        else { throw ArchiveError.badRoute }
        return value
    }

    func validated() throws -> PublicRoute {
        guard version == 1, (1...120).contains(stations.count) else { throw ArchiveError.badRoute }
        var keys = Set<[String]>()
        let stops = try stations.compactMap { stop -> Stop? in
            let name = try Self.clean(stop.name)
            let region = try Self.clean(stop.region, allowEmpty: true)
            guard keys.insert([Search.normalized(name), Search.normalized(region)]).inserted else { return nil }
            return Stop(name: name, region: region)
        }
        return try PublicRoute(name: Self.clean(name), stations: stops)
    }

    func data() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(validated())
    }

    func code() throws -> String {
        try "GS1:" + data().base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func read(_ code: String) throws -> PublicRoute {
        let value = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.utf8.count <= maxBytes * 2, value.hasPrefix("GS1:") else { throw ArchiveError.badRoute }
        let base = value.dropFirst(4)
        guard !base.isEmpty, base.utf8.allSatisfy({ byte in
            (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte) || byte == 45 || byte == 95
        }) else { throw ArchiveError.badRoute }
        let input = String(base).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let padding = String(repeating: "=", count: (4 - input.count % 4) % 4)
        guard let data = Data(base64Encoded: input + padding) else { throw ArchiveError.badRoute }
        return try read(data)
    }

    static func read(_ data: Data) throws -> PublicRoute {
        guard data.count <= maxBytes, let route = try? JSONDecoder().decode(Self.self, from: data)
        else { throw ArchiveError.badRoute }
        return try route.validated()
    }

    func makeRoute() -> Route {
        Route(name: name, stations: stations.map { Station(name: $0.name, region: $0.region) })
    }

    func matches(_ route: Route) -> Bool {
        func key(_ value: PublicRoute) -> [[String]] {
            [[Search.normalized(value.name)]] + value.stations.map {
                [Search.normalized($0.name), Search.normalized($0.region)]
            }
        }
        return key(self) == key(PublicRoute(route))
    }
}
