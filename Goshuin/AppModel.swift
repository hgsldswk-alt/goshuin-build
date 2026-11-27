import ActivityKit
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let goshuinRoute = UTType(exportedAs: "com.hgsldswk.goshuin.route", conformingTo: .json)
    static let goshuinBackup = UTType(exportedAs: "com.hgsldswk.goshuin.backup", conformingTo: .data)
}

@MainActor
final class AppModel: ObservableObject {
    nonisolated static let testing = ProcessInfo.processInfo.arguments.contains("-ui-testing")
    nonisolated static let arguments = ProcessInfo.processInfo.arguments
    @Published private(set) var archive = Archive()
    @Published private(set) var worker: Library?
    @Published private(set) var busy = false
    @Published var error: String?
    @Published var savedIDs: [UUID] = []
    @Published var savedToken = UUID()
    @Published var visitedUndo: (route: UUID, station: UUID)?
    @Published var fixtureDate = String(VisitDay.key(Date()).prefix(7))
    private var pendingPhotos: ([IncomingPhoto], UUID)?
    private var pendingUndo: Task<Void, Never>?
    private var activityTask: Task<Void, Never>?

    var canRetryPhoto: Bool { pendingPhotos != nil }

    func start() async {
        guard worker == nil, !busy else { return }
        busy = true
        defer { busy = false }
        do {
            let sampleMode = Self.testing && Self.arguments.contains("-samples")
            let (library, seed, sample) = try await Task.detached {
                let files = FileManager.default
                let root = try files.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                         appropriateFor: nil, create: true)
                let folder = root.appendingPathComponent(Self.testing ? "Goshuin-UITests" : "Goshuin")
                if Self.testing && Self.arguments.contains("-reset"), files.fileExists(atPath: folder.path) {
                    try files.removeItem(at: folder)
                }
                let seed = sampleMode ? Examples.archive() : nil
                let sample = try sampleMode ? Examples.photo() : nil
                return (try Library(folder: folder), seed, sample)
            }.value
            archive = try await library.load(seed: seed, sample: sample)
            worker = library
            if sampleMode { fixtureDate = "2026-11" }
        } catch {
            self.error = L.t("error.open")
        }
    }

    @discardableResult
    func edit(_ edit: (inout Archive) throws -> Void) async -> Bool {
        guard let worker, !busy else { return false }
        busy = true
        defer { busy = false }
        do {
            var next = archive
            try edit(&next)
            try await worker.write(next)
            archive = next
            refreshActivity()
            return true
        } catch {
            report(error)
            return false
        }
    }

    func report(_ error: Error) {
        self.error = (error as? ArchiveError)?.localizedDescription ?? L.t("error.storage")
    }

    func savePhotos(_ photos: [IncomingPhoto], book: UUID?) async {
        guard let worker, !busy, let book = book ?? archive.books.first?.id else { return }
        pendingPhotos = (photos, book)
        busy = true
        defer { busy = false }
        do {
            let (next, ids) = try await worker.append(photos, to: book, in: archive)
            archive = next
            pendingPhotos = nil
            savedIDs = ids
            savedToken = UUID()
            for _ in ids { CoreReview.shared.record() }
            pendingUndo?.cancel()
            pendingUndo = Task { [weak self] in
                try? await Task.sleep(for: .seconds(8))
                guard !Task.isCancelled else { return }
                self?.savedIDs = []
            }
        } catch { report(error) }
    }

    func retryPhoto() async {
        guard let (photos, book) = pendingPhotos else { return }
        await savePhotos(photos, book: book)
    }

    func undoSave() async {
        let ids = Set(savedIDs)
        guard !ids.isEmpty else { return }
        if await edit({ archive in
            for index in archive.entries.indices where ids.contains(archive.entries[index].id) {
                archive.entries[index].deletedAt = Date()
            }
        }) { savedIDs = [] }
    }

    func mark(route: UUID, station: UUID) async {
        if await edit({ $0.toggle(route: route, station: station) }) {
            visitedUndo = (route, station)
        }
    }

    func addRoute(_ publicRoute: PublicRoute, canAdd: Bool) async -> Bool {
        await edit { archive in
            guard !archive.routes.contains(where: publicRoute.matches) else { throw ArchiveError.duplicate }
            guard archive.routes.isEmpty || canAdd else { throw ArchiveError.stale }
            let route = publicRoute.makeRoute()
            archive.routes.append(route)
            archive.currentRoute = route.id
        }
    }

    func addTemplate(canAdd: Bool) async {
        let (temples, route) = Examples.template()
        _ = await edit { archive in
            guard !archive.routes.contains(where: PublicRoute(route).matches) else { throw ArchiveError.duplicate }
            guard archive.routes.isEmpty || canAdd else { throw ArchiveError.stale }
            var route = route
            for index in temples.indices {
                let temple = temples[index]
                if let match = archive.temples.first(where: { $0.place == temple.place && $0.name == temple.name }) {
                    route.stations[index].templeID = match.id
                } else {
                    archive.temples.append(temple)
                }
            }
            archive.routes.append(route)
            archive.currentRoute = route.id
        }
    }

    func restore(_ plan: RestorePlan) async -> Bool {
        guard let worker, !busy else { return false }
        guard archive == plan.original else { self.error = L.t("error.stale"); return false }
        busy = true
        defer { busy = false }
        do {
            try await worker.write(plan.merged, photos: plan.photos)
            archive = plan.merged
            refreshActivity()
            return true
        } catch { report(error); return false }
    }

    func startActivity(_ route: Route) async {
        guard !Self.testing, ActivityAuthorizationInfo().areActivitiesEnabled else {
            self.error = L.t("activity.unavailable")
            return
        }
        for value in Activity<PilgrimageActivity>.activities {
            await value.end(nil, dismissalPolicy: .immediate)
        }
        do {
            _ = try Activity.request(attributes: PilgrimageActivity(routeID: route.id),
                                     content: ActivityContent(state: .init(visited: route.visited, total: route.stations.count),
                                                              staleDate: nil))
            refreshActivity()
        } catch { self.error = L.t("activity.unavailable") }
    }

    func stopActivity() async {
        activityTask?.cancel()
        for value in Activity<PilgrimageActivity>.activities {
            await value.end(nil, dismissalPolicy: .immediate)
        }
    }

    private func refreshActivity() {
        guard !Self.testing else { return }
        activityTask?.cancel()
        activityTask = Task { [archive] in
            for value in Activity<PilgrimageActivity>.activities {
                guard !Task.isCancelled else { return }
                if let route = archive.routes.first(where: { $0.id == value.attributes.routeID }) {
                    let content = ActivityContent(state: PilgrimageActivity.ContentState(
                        visited: route.visited, total: route.stations.count), staleDate: nil)
                    if route.complete { await value.end(content, dismissalPolicy: .default) }
                    else { await value.update(content) }
                } else {
                    await value.end(nil, dismissalPolicy: .immediate)
                }
            }
        }
    }
}

enum Examples {
    static func photo() throws -> Data {
        guard let url = Bundle.main.url(forResource: "stamp-sample", withExtension: "jpg")
        else { throw ArchiveError.missing }
        return try Data(contentsOf: url)
    }

    static func template() -> ([Temple], Route) {
        let places = [
            ("kitano", 35.0311, 135.7351), ("kamigamo", 35.0605, 135.7524),
            ("shimogamo", 35.0389, 135.7726), ("heian", 35.0161, 135.7824),
            ("yasaka", 35.0037, 135.7785), ("kiyomizu", 34.9948, 135.7850),
            ("toji", 34.9806, 135.7477)
        ]
        let temples = places.map {
            Temple(name: L.t("example." + $0.0), region: L.t("region.26"),
                   place: Place(latitude: $0.1, longitude: $0.2))
        }
        return (temples, Route(name: L.t("example.route"), stations: temples.map {
            Station(name: $0.name, region: $0.region, templeID: $0.id)
        }))
    }

    static func archive() -> Archive {
        var archive = Archive()
        var (temples, route) = template()
        temples[0].name = L.t("example.fictional")
        temples[0].kana = "あさなぎじんじゃ"
        route.stations[0].name = temples[0].name
        for index in 0..<4 { route.stations[index].visitedAt = Date() }
        archive.temples = temples
        archive.routes = [route]
        archive.currentRoute = route.id
        let book = archive.books[0].id
        let asset = UUID()
        archive.entries = (0..<5).map { index in
            StampEntry(bookID: book, assetID: asset, order: index,
                       addedAt: Date(timeIntervalSince1970: 1_795_212_000 + Double(index)), visitDay: "2026-11-2\(index)",
                       templeID: temples[index == 4 ? 0 : index].id, source: .sample)
        }
        return archive
    }
}
