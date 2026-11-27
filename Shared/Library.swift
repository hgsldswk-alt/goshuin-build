import Foundation
import SwiftData
import UIKit

@Model
final class ArchiveRecord {
    var payload: Data
    init(payload: Data) { self.payload = payload }
}

protocol ArchiveRow {
    var key: UUID { get }
    var position: Int { get set }
    var payload: Data { get set }
    init(key: UUID, position: Int, payload: Data)
}

@Model
final class BookRow: ArchiveRow {
    @Attribute(.unique) var key: UUID
    var position: Int
    var payload: Data

    init(key: UUID, position: Int, payload: Data) {
        self.key = key
        self.position = position
        self.payload = payload
    }
}

@Model
final class StampRow: ArchiveRow {
    @Attribute(.unique) var key: UUID
    var position: Int
    var payload: Data

    init(key: UUID, position: Int, payload: Data) {
        self.key = key
        self.position = position
        self.payload = payload
    }
}

@Model
final class TempleRow: ArchiveRow {
    @Attribute(.unique) var key: UUID
    var position: Int
    var payload: Data

    init(key: UUID, position: Int, payload: Data) {
        self.key = key
        self.position = position
        self.payload = payload
    }
}

@Model
final class RouteRow: ArchiveRow {
    @Attribute(.unique) var key: UUID
    var position: Int
    var payload: Data

    init(key: UUID, position: Int, payload: Data) {
        self.key = key
        self.position = position
        self.payload = payload
    }
}

struct IncomingPhoto {
    var data: Data
    var source: StampEntry.Source
    var takenAt: Date?
    var visitDay: String?

    static func fromLibrary(_ data: Data) -> Self {
        let (date, day) = StampImages.captureDate(data)
        return Self(data: data, source: .library, takenAt: date, visitDay: day)
    }

    static func fromCamera(_ data: Data, at date: Date = Date()) -> Self {
        Self(data: data, source: .camera, takenAt: date, visitDay: VisitDay.key(date))
    }
}

actor Library: ModelActor {
    nonisolated let modelContainer: ModelContainer
    nonisolated let modelExecutor: any ModelExecutor
    let folder: URL

    init(folder: URL) throws {
        self.folder = folder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        let schema = Schema([ArchiveRecord.self, BookRow.self, StampRow.self, TempleRow.self, RouteRow.self])
        let configuration = ModelConfiguration(schema: schema, url: folder.appendingPathComponent("library.store"),
                                               cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        modelContainer = container
        let context = ModelContext(container)
        context.autosaveEnabled = false
        modelExecutor = DefaultSerialModelExecutor(modelContext: context)
    }

    func load(seed: Archive? = nil, sample: Data? = nil) throws -> Archive {
        if let existing = try modelContext.fetch(FetchDescriptor<ArchiveRecord>()).first {
            let decoder = JSONDecoder()
            var library = try decoder.decode(Archive.self, from: existing.payload)
            if library.books.isEmpty {
                library.books = try readRows(BookRow.self, decoder: decoder)
                library.entries = try readRows(StampRow.self, decoder: decoder)
                library.temples = try readRows(TempleRow.self, decoder: decoder)
                library.routes = try readRows(RouteRow.self, decoder: decoder)
                guard !library.books.isEmpty else { throw ArchiveError.missing }
            } else {
                try write(library)
            }
            try cleanOrphanImages(keep: Set(library.entries.map(\.assetID)))
            return library
        }
        let archive = seed ?? Archive()
        let samplePhotos = sample.map { data in
            Set(archive.entries.map(\.assetID)).map { BackupPhoto(id: $0, data: data) }
        } ?? []
        try write(archive, photos: samplePhotos)
        try cleanOrphanImages(keep: Set(archive.entries.map(\.assetID)))
        return archive
    }

    private func readRows<Row: ArchiveRow & PersistentModel, Item: Decodable>(_ type: Row.Type,
                                                                             decoder: JSONDecoder) throws -> [Item] {
        try modelContext.fetch(FetchDescriptor<Row>()).sorted { $0.position < $1.position }
            .map { try decoder.decode(Item.self, from: $0.payload) }
    }

    private func writeRows<Row: ArchiveRow & PersistentModel, Item: Encodable & Identifiable>(
        _ type: Row.Type, items: [Item], encoder: JSONEncoder
    ) throws where Item.ID == UUID {
        let rows = try modelContext.fetch(FetchDescriptor<Row>())
        var stored = Dictionary(uniqueKeysWithValues: rows.map { ($0.key, $0) })
        for (position, item) in items.enumerated() {
            let payload = try encoder.encode(item)
            if var row = stored.removeValue(forKey: item.id) {
                if row.position != position { row.position = position }
                if row.payload != payload { row.payload = payload }
            } else {
                modelContext.insert(Row(key: item.id, position: position, payload: payload))
            }
        }
        for row in stored.values { modelContext.delete(row) }
    }

    private func path(_ id: UUID, thumbnail: Bool = false) -> URL {
        folder.appendingPathComponent(id.uuidString + (thumbnail ? ".thumb" : ".image"))
    }

    private func cleanOrphanImages(keep: Set<UUID>) throws {
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        for file in files where ["thumb", "image"].contains(file.pathExtension) {
            guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent), !keep.contains(id) else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }

    static func checkSpace(required: Int, available: Int64?) throws {
        if let available, available < Int64(required) + 5_000_000 { throw ArchiveError.lowSpace }
    }

    func write(_ archive: Archive, photos: [BackupPhoto] = []) throws {
        let available = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage
        try Self.checkSpace(required: photos.reduce(0) { $0 + $1.data.count + 200_000 }, available: available)
        let files = FileManager.default
        var staged: [URL] = []
        do {
            for photo in photos {
                try Task.checkCancellation()
                let image = try StampImages.image(photo.data, maxPixel: 550)
                guard let thumbnail = image.jpegData(compressionQuality: 0.78) else { throw ArchiveError.badPhoto }
                let originalURL = path(photo.id)
                let thumbnailURL = path(photo.id, thumbnail: true)
                guard !files.fileExists(atPath: originalURL.path) else { throw ArchiveError.stale }
                staged.append(contentsOf: [originalURL, thumbnailURL])
                let options: Data.WritingOptions = [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
                try photo.data.write(to: originalURL, options: options)
                try thumbnail.write(to: thumbnailURL, options: options)
            }
            try Task.checkCancellation()
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            try writeRows(BookRow.self, items: archive.books, encoder: encoder)
            try writeRows(StampRow.self, items: archive.entries, encoder: encoder)
            try writeRows(TempleRow.self, items: archive.temples, encoder: encoder)
            try writeRows(RouteRow.self, items: archive.routes, encoder: encoder)
            var metadata = archive
            metadata.books = []
            metadata.entries = []
            metadata.temples = []
            metadata.routes = []
            let payload = try encoder.encode(metadata)
            let record = try modelContext.fetch(FetchDescriptor<ArchiveRecord>()).first
            if let record { record.payload = payload }
            else { modelContext.insert(ArchiveRecord(payload: payload)) }
            try modelContext.save()
        } catch {
            modelContext.rollback()
            for url in staged { try? files.removeItem(at: url) }
            throw error
        }
    }

    func append(_ items: [IncomingPhoto], to bookID: UUID, in input: Archive) throws -> (Archive, [UUID]) {
        guard !items.isEmpty, input.books.contains(where: { $0.id == bookID }) else { throw ArchiveError.missing }
        var archive = input
        let next = archive.entries.lazy.filter { $0.bookID == bookID }.map(\.order).max() ?? 0
        var ids: [UUID] = []
        var photos: [BackupPhoto] = []
        for (index, item) in items.enumerated() {
            let order = next + items.count - index
            let entry = StampEntry(bookID: bookID, order: order, addedDay: VisitDay.key(Date()), capturedAt: item.takenAt,
                                   visitDay: item.visitDay, source: item.source)
            photos.append(BackupPhoto(id: entry.assetID, data: item.data))
            ids.append(entry.id)
            archive.entries.append(entry)
        }
        archive.checkPageMilestones()
        try write(archive, photos: photos)
        return (archive, ids)
    }

    func image(for entry: StampEntry, thumbnail: Bool, uncropped: Bool = false) throws -> UIImage {
        let small = path(entry.assetID, thumbnail: true)
        let useThumbnail = thumbnail && FileManager.default.fileExists(atPath: small.path)
        let url = path(entry.assetID, thumbnail: useThumbnail)
        return try StampImages.image(Data(contentsOf: url), maxPixel: thumbnail ? 550 : 5200,
                                     crop: uncropped ? nil : entry.crop)
    }

    func share(entries: [StampEntry], title: String, caption: String, storeID: String?) throws -> Data {
        let images = try entries.map { entry in
            try StampImages.image(Data(contentsOf: path(entry.assetID)), maxPixel: 1250, crop: entry.crop)
        }
        return try ShareArtwork.render(title: title, caption: caption, images: images, storeID: storeID)
    }

    func export(_ archive: Archive, filename: String = "Goshuin.goshuinbackup") throws -> URL {
        var bytes = 0
        var index: [BackupPackage.PhotoIndex] = []
        for id in Set(archive.entries.map(\.assetID)).sorted(by: { $0.uuidString < $1.uuidString }) {
            try Task.checkCancellation()
            let url = path(id)
            let length = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard (1...StampImages.maxBytes).contains(length), bytes <= BackupPackage.maxBytes - length
            else { throw ArchiveError.tooLarge }
            bytes += length
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            index.append(.init(id: id, checksum: BackupPackage.hash(data), byteCount: length))
        }
        let header = try BackupPackage.header(archive: archive, photos: index)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let available = try? FileManager.default.temporaryDirectory
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
        try Self.checkSpace(required: bytes + header.count, available: available)
        let file = folder.appendingPathComponent(filename)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                    attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            try header.write(to: file, options: .completeFileProtectionUntilFirstUserAuthentication)
            let writer = try FileHandle(forWritingTo: file)
            defer { try? writer.close() }
            try writer.seekToEnd()
            for item in index {
                try Task.checkCancellation()
                try writer.write(contentsOf: Data(contentsOf: path(item.id), options: .mappedIfSafe))
            }
            try writer.synchronize()
            return file
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    func previewRestore(_ data: Data, current: Archive) throws -> RestorePlan {
        let (checksum, manifest) = try BackupPackage.decode(data)
        let incomingID = Set(manifest.photos.map(\.id))
        var hashes: [UUID: String] = [:]
        for id in Set(current.entries.map(\.assetID)).intersection(incomingID) {
            if let data = try? Data(contentsOf: path(id)) { hashes[id] = BackupPackage.hash(data) }
        }
        let plan = RestorePlan.make(current: current, checksum: checksum, manifest: manifest, existingHashes: hashes)
        let available = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage
        try Self.checkSpace(required: plan.byteCount + plan.photos.count * 200_000, available: available)
        return plan
    }
}
