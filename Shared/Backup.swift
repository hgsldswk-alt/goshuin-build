import CryptoKit
import Foundation

struct BackupPhoto: Codable {
    var id: UUID
    var checksum: String
    var data: Data

    init(id: UUID, data: Data) {
        self.id = id
        self.data = data
        checksum = BackupPackage.hash(data)
    }
}

struct BackupManifest: Codable {
    var version = 1
    var archive: Archive
    var photos: [BackupPhoto]
}

enum BackupPackage {
    static let maxBytes = 1_500_000_000
    static let maxIndexBytes = 24_000_000
    private static let magic = Data("GSBACK1\n".utf8)
    private static let checksumLength = 64
    private static let lengthWidth = 8

    struct PhotoIndex: Codable {
        var id: UUID
        var checksum: String
        var byteCount: Int
    }

    private struct Index: Codable {
        var version: Int
        var archive: Archive
        var photos: [PhotoIndex]
    }

    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func encode(_ manifest: BackupManifest) throws -> Data {
        let index = manifest.photos.map {
            PhotoIndex(id: $0.id, checksum: $0.checksum, byteCount: $0.data.count)
        }
        var bytes = try header(archive: manifest.archive, photos: index, version: manifest.version)
        for photo in manifest.photos { bytes.append(photo.data) }
        return bytes
    }

    static func header(archive: Archive, photos: [PhotoIndex], version: Int = 1) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let index = try encoder.encode(Index(version: version, archive: archive, photos: photos))
        let headerSize = magic.count + lengthWidth + checksumLength + index.count
        guard index.count <= maxIndexBytes, photos.reduce(headerSize, { $0 + $1.byteCount }) <= maxBytes
        else { throw ArchiveError.tooLarge }
        var length = UInt64(index.count).bigEndian
        var bytes = magic
        withUnsafeBytes(of: &length) { bytes.append(contentsOf: $0) }
        bytes.append(contentsOf: hash(index).utf8)
        bytes.append(index)
        return bytes
    }

    static func decode(_ bytes: Data) throws -> (String, BackupManifest) {
        guard bytes.count <= maxBytes else { throw ArchiveError.tooLarge }
        let lengthStart = bytes.startIndex + magic.count
        let checksumStart = lengthStart + lengthWidth
        let indexStart = checksumStart + checksumLength
        guard bytes.endIndex >= indexStart, bytes.starts(with: magic) else { throw ArchiveError.badBackup }
        let length = bytes[lengthStart..<checksumStart].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        guard length <= UInt64(maxIndexBytes), Int(length) <= bytes.endIndex - indexStart
        else { throw ArchiveError.badBackup }
        let indexEnd = indexStart + Int(length)
        let data = bytes[indexStart..<indexEnd]
        let checksum = hash(data)
        guard String(decoding: bytes[checksumStart..<indexStart], as: UTF8.self) == checksum,
              let index = try? JSONDecoder().decode(Index.self, from: data),
              index.version == 1, index.photos.count <= 30_000 else { throw ArchiveError.badBackup }
        var offset = indexEnd
        var photos: [BackupPhoto] = []
        for photo in index.photos {
            guard (1...StampImages.maxBytes).contains(photo.byteCount), photo.byteCount <= bytes.endIndex - offset
            else { throw ArchiveError.badBackup }
            let data = bytes[offset..<(offset + photo.byteCount)]
            let asset = BackupPhoto(id: photo.id, data: data)
            guard asset.checksum == photo.checksum else { throw ArchiveError.badBackup }
            photos.append(asset)
            offset += photo.byteCount
        }
        guard offset == bytes.endIndex else { throw ArchiveError.badBackup }
        let manifest = BackupManifest(archive: index.archive, photos: photos)
        try validate(manifest)
        return (checksum, manifest)
    }

    static func validate(_ manifest: BackupManifest) throws {
        let archive = manifest.archive
        let books = Set(archive.books.map(\.id))
        let entries = Set(archive.entries.map(\.id))
        let temples = Set(archive.temples.map(\.id))
        let routes = Set(archive.routes.map(\.id))
        let photos = Set(manifest.photos.map(\.id))
        guard !books.isEmpty, books.count == archive.books.count, books.count <= 500,
              entries.count == archive.entries.count, entries.count <= 30_000,
              temples.count == archive.temples.count, temples.count <= 30_000,
              routes.count == archive.routes.count, routes.count <= 500,
              photos.count == manifest.photos.count, photos == Set(archive.entries.map(\.assetID)),
              archive.currentRoute.map(routes.contains) ?? true,
              archive.temples.allSatisfy({ $0.place?.isValid ?? true }) else { throw ArchiveError.badBackup }
        for entry in archive.entries {
            guard books.contains(entry.bookID), entry.templeID.map(temples.contains) ?? true,
                  entry.visitDay == nil || VisitDay.date(entry.visitDay) != nil,
                  entry.addedDay == nil || VisitDay.date(entry.addedDay) != nil,
                  entry.crop?.isValid ?? true, (0..<1_000_000_000).contains(entry.order),
                  (0..<1_000_000_000).contains(entry.revision) else { throw ArchiveError.badBackup }
        }
        for route in archive.routes {
            let validated = try PublicRoute(route).validated()
            guard validated.stations.count == route.stations.count,
                  Set(route.stations.map(\.id)).count == route.stations.count,
                  route.stations.allSatisfy({ $0.templeID.map(temples.contains) ?? true })
            else { throw ArchiveError.badBackup }
        }
        for photo in manifest.photos {
            _ = try StampImages.validate(photo.data)
        }
    }
}

struct RestorePlan {
    var original: Archive
    var merged: Archive
    var photos: [BackupPhoto]
    var newEntries: Int
    var conflicts: Int

    var byteCount: Int { photos.reduce(0) { $0 + $1.data.count } }

    static func make(current: Archive, checksum: String, manifest: BackupManifest,
                     existingHashes: [UUID: String]) -> RestorePlan {
        var plan = RestorePlan(original: current, merged: current, photos: [], newEntries: 0, conflicts: 0)
        guard !current.restoredPackages.contains(checksum) else { return plan }
        func merge<T: Identifiable & Equatable>(_ items: [T], into list: inout [T],
                                                  setID: (inout T, UUID) -> Void) -> ([UUID: UUID], Int)
        where T.ID == UUID {
            var mapping: [UUID: UUID] = [:]
            var conflicts = 0
            var existingByID = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
            for item in items {
                var copy = item
                if let existing = existingByID[item.id] {
                    if existing == item { continue }
                    let id = UUID()
                    setID(&copy, id)
                    mapping[item.id] = id
                    conflicts += 1
                }
                list.append(copy)
                existingByID[copy.id] = copy
            }
            return (mapping, conflicts)
        }
        let incoming = manifest.archive
        if current.entries.isEmpty, current.temples.isEmpty, current.routes.isEmpty,
           current.books.count == 1, current.books.first?.name == L.t("book.default") {
            plan.merged.books = []
        }
        let (books, bookConflicts) = merge(incoming.books, into: &plan.merged.books) { $0.id = $1 }
        let (temples, templeConflicts) = merge(incoming.temples, into: &plan.merged.temples) { $0.id = $1 }
        var assets: [UUID: UUID] = [:]
        for photo in manifest.photos {
            var copy = photo
            if let old = existingHashes[photo.id] {
                if old == photo.checksum { continue }
                copy.id = UUID()
                assets[photo.id] = copy.id
            }
            plan.photos.append(copy)
        }
        let entries = incoming.entries.map { entry in
            var item = entry
            item.bookID = books[entry.bookID] ?? entry.bookID
            item.templeID = entry.templeID.map { temples[$0] ?? $0 }
            item.assetID = assets[entry.assetID] ?? entry.assetID
            return item
        }
        let (_, entryConflicts) = merge(entries, into: &plan.merged.entries) { $0.id = $1 }
        let routes = incoming.routes.map { route in
            var copy = route
            for index in copy.stations.indices {
                copy.stations[index].templeID = copy.stations[index].templeID.map { temples[$0] ?? $0 }
            }
            return copy
        }
        let (routeIDs, routeConflicts) = merge(routes, into: &plan.merged.routes) { $0.id = $1 }
        if plan.merged.currentRoute == nil {
            plan.merged.currentRoute = incoming.currentRoute.map { routeIDs[$0] ?? $0 }
        }
        plan.merged.achieved.formUnion(incoming.achieved)
        for (old, new) in routeIDs where incoming.achieved.contains("route:" + old.uuidString) {
            plan.merged.achieved.insert("route:" + new.uuidString)
        }
        plan.merged.restoredPackages.insert(checksum)
        plan.newEntries = plan.merged.entries.count - current.entries.count
        plan.conflicts = bookConflicts + templeConflicts + entryConflicts + routeConflicts
        return plan
    }
}
