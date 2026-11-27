import Foundation
import CoreImage
import ImageIO
import UIKit
import XCTest

final class ArchiveTests: XCTestCase {
    func testCoreReviewRequiresThreeActionsOnTwoLocalDates() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        let firstDay = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 23, hour: 23)))
        let nextDay = firstDay.addingTimeInterval(2 * 3600)
        let empty = try JSONDecoder().decode(CoreReviewProgress.self, from: Data("{}".utf8))
        XCTAssertFalse(empty.isEligible)
        var progress = CoreReviewProgress.recording(empty, at: firstDay, calendar: calendar)
        var twoDays = progress
        twoDays.record(at: nextDay, calendar: calendar)
        XCTAssertFalse(twoDays.isEligible)
        progress.record(at: firstDay, calendar: calendar)
        XCTAssertFalse(progress.isEligible)

        var sameDay = progress
        sameDay.record(at: firstDay, calendar: calendar)
        XCTAssertFalse(sameDay.isEligible)

        let data = try JSONEncoder().encode(progress)
        progress = try JSONDecoder().decode(CoreReviewProgress.self, from: data)
        progress.record(at: nextDay, calendar: calendar)
        XCTAssertTrue(progress.isEligible)
    }

    func testTrialBoundsAndVerifiedEarlierDate() {
        let firstOpen = Date(timeIntervalSince1970: 1_700_000_000)
        let paidLaunch = firstOpen.addingTimeInterval(1000)
        var entitlement = Entitlement(firstOpen: firstOpen, proStartedAt: paidLaunch)
        XCTAssertEqual(entitlement.trialStart, paidLaunch)
        XCTAssertTrue(entitlement.hasPro(at: paidLaunch, free: false))
        XCTAssertFalse(entitlement.hasPro(at: paidLaunch.addingTimeInterval(-1), free: false))
        XCTAssertTrue(entitlement.hasPro(at: entitlement.trialEnd.addingTimeInterval(-1), free: false))
        XCTAssertFalse(entitlement.hasPro(at: entitlement.trialEnd, free: false))
        entitlement.trialClaimedAt = paidLaunch.addingTimeInterval(200)
        XCTAssertEqual(entitlement.trialStart, paidLaunch)
        entitlement.trialClaimedAt = firstOpen
        XCTAssertEqual(entitlement.trialStart, firstOpen)
        entitlement.purchasedPro = true
        XCTAssertTrue(entitlement.hasPro(at: .distantFuture, free: false))
        entitlement.purchasedPro = false
        XCTAssertFalse(entitlement.hasPro(at: .distantFuture, free: false))
        XCTAssertTrue(entitlement.hasPro(at: .distantFuture, free: true))
        XCTAssertEqual(Entitlement(firstOpen: firstOpen).trialStart, firstOpen)
    }

    func testSearchDatesStableIdentityAndPageOrder() throws {
        XCTAssertEqual(Search.normalized(" ﾀｶｻｷ 髙﨑 神社 "), "たかさき 高崎 神社")
        let utc = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let tokyo = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        let visit = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-20T23:30:00Z"))
        XCTAssertEqual(VisitDay.key(visit, zone: utc), "2026-11-20")
        XCTAssertEqual(VisitDay.key(visit, zone: tokyo), "2026-11-21")
        XCTAssertNil(VisitDay.date("2026-02-30"))
        var archive = Archive()
        let kyoto = Temple(name: "神社", kana: "ジンジャ", region: "京都府")
        let osaka = Temple(name: "神社", kana: "じんじゃ", region: "大阪府")
        archive.temples = [kyoto, osaka]
        let first = StampEntry(bookID: archive.books[0].id, order: 1, visitDay: "2026-11-21", templeID: kyoto.id, source: .library)
        let second = StampEntry(bookID: first.bookID, order: 2, visitDay: first.visitDay, templeID: osaka.id, source: .camera)
        let unknown = StampEntry(bookID: first.bookID, order: 3, source: .library)
        archive.entries = [first, second, unknown]
        XCTAssertEqual(archive.filtered(book: nil, query: "ｼﾞﾝｼﾞｬ", month: "2026-11").map(\.id), [second.id, first.id])
        XCTAssertEqual(archive.filtered(book: nil, query: "京都", month: nil).map(\.id), [first.id])
        XCTAssertEqual(archive.filtered(book: nil, query: "", month: "unknown").map(\.id), [unknown.id])
        XCTAssertEqual(archive.paperOrder(archive.active).map(\.id), [unknown.id, second.id, first.id])
        archive.changeOrder([first.id, unknown.id, second.id], in: first.bookID)
        XCTAssertEqual(archive.paperOrder(archive.active).map(\.id), [first.id, unknown.id, second.id])
        XCTAssertEqual(archive.filtered(book: nil, query: "", month: "2026-11").map(\.id), [first.id, second.id])
        XCTAssertNotEqual(kyoto.id, osaka.id)
        XCTAssertNil(kyoto.place)
        XCTAssertFalse(Place(latitude: .infinity, longitude: 139).isValid)
    }

    func testRouteCodeIsPublicDeduplicatedAndMilestonesAreOnceOnly() throws {
        let temple = UUID()
        let route = Route(name: "週末巡礼", stations: [
            Station(name: "神社", region: "京都", templeID: temple, visitedAt: Date()),
            Station(name: "神社", region: "京都"),
            Station(name: "神社", region: "大阪")
        ])
        let publicRoute = PublicRoute(route)
        let data = try publicRoute.data()
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let stations = try XCTUnwrap(json["stations"] as? [[String: Any]])
        XCTAssertEqual(stations.count, 2)
        XCTAssertEqual(Set(stations[0].keys), Set(["name", "region"]))
        let decoded = try PublicRoute.read(publicRoute.code())
        XCTAssertEqual(decoded, try PublicRoute.read(data))
        XCTAssertThrowsError(try PublicRoute.read("GS1:/+"))
        XCTAssertThrowsError(try PublicRoute.read(Data(repeating: 0, count: PublicRoute.maxBytes + 1)))
        let imported = decoded.makeRoute()
        XCTAssertEqual(imported.visited, 0)
        XCTAssertTrue(imported.stations.allSatisfy { $0.templeID == nil })
        XCTAssertTrue(decoded.matches(imported))
        var archive = Archive()
        archive.routes = [imported]
        for station in imported.stations { archive.toggle(route: imported.id, station: station.id) }
        let last = try XCTUnwrap(imported.stations.last)
        archive.toggle(route: imported.id, station: last.id)
        archive.toggle(route: imported.id, station: last.id)
        XCTAssertEqual(archive.pending.count, 1)
        XCTAssertTrue(archive.routes[0].complete)
        XCTAssertFalse(archive.canRequestRating)
        for index in 0..<50 {
            archive.entries.append(StampEntry(bookID: archive.books[0].id, order: index,
                                              addedDay: "2026-11-2\(index % 3)",
                                              visitDay: "2026-11-2\(index % 3)", source: .camera))
        }
        archive.checkPageMilestones()
        archive.checkPageMilestones()
        XCTAssertEqual(archive.pending.count, 3)
        XCTAssertTrue(archive.canRequestRating)
    }

    func testBackupChecksumAssociationsAndRepeatRestore() throws {
        let data = try photo()
        var archive = Archive()
        let entry = StampEntry(bookID: archive.books[0].id, order: 0, source: .camera)
        archive.entries = [entry]
        let bytes = try BackupPackage.encode(.init(archive: archive, photos: [BackupPhoto(id: entry.assetID, data: data)]))
        let (checksum, manifest) = try BackupPackage.decode(bytes)
        let empty = Archive()
        let first = RestorePlan.make(current: empty, checksum: checksum, manifest: manifest, existingHashes: [:])
        XCTAssertEqual(first.newEntries, 1)
        XCTAssertEqual(first.conflicts, 0)
        XCTAssertEqual(first.original, empty)
        XCTAssertEqual(first.merged.active.first?.assetID, entry.assetID)
        XCTAssertEqual(first.photos.count, 1)
        let repeated = RestorePlan.make(current: first.merged, checksum: checksum, manifest: manifest,
                                        existingHashes: [entry.assetID: BackupPackage.hash(data)])
        XCTAssertEqual(repeated.newEntries, 0)
        XCTAssertTrue(repeated.photos.isEmpty)
        var changed = archive
        changed.entries[0].visitDay = "2026-11-21"
        let conflict = RestorePlan.make(current: changed, checksum: checksum, manifest: manifest,
                                        existingHashes: [entry.assetID: BackupPackage.hash(data)])
        XCTAssertEqual(conflict.conflicts, 1)
        XCTAssertEqual(conflict.merged.entries.count, 2)
        XCTAssertThrowsError(try BackupPackage.decode(bytes.dropLast()))
        XCTAssertThrowsError(try BackupPackage.validate(.init(archive: archive, photos: [])))
    }

    func testFailedMultiPhotoWriteLeavesNoPartialFilesAndReopens() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try await Task.detached { try Library(folder: root) }.value
        let archive = try await library.load()
        let data = try photo()
        do {
            _ = try await library.append([.fromLibrary(data), .fromLibrary(Data([0, 1, 2]))],
                                         to: archive.books[0].id, in: archive)
            XCTFail("A failed import must roll back.")
        } catch {}
        let filenames = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertFalse(filenames.contains { $0.hasSuffix(".image") || $0.hasSuffix(".thumb") })
        let reopened = try await library.load()
        XCTAssertEqual(reopened, archive)
        let (saved, ids) = try await library.append([.fromLibrary(data)], to: archive.books[0].id, in: archive)
        XCTAssertEqual(saved.entries.count, 1)
        XCTAssertEqual(ids.first, saved.entries.first?.id)
        let loaded = try await library.load()
        XCTAssertEqual(loaded, saved)
        XCTAssertNil(loaded.active.first?.visitDay)
        XCTAssertThrowsError(try Library.checkSpace(required: 1_000_000, available: 50))

        let canceled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await library.append([.fromLibrary(data)], to: archive.books[0].id, in: loaded)
        }
        do {
            _ = try await canceled.value
            XCTFail("Canceled import committed a page.")
        } catch is CancellationError {}
        let afterCancel = try await library.load()
        XCTAssertEqual(afterCancel, loaded)

        let export = try await library.export(afterCancel)
        defer { try? FileManager.default.removeItem(at: export.deletingLastPathComponent()) }
        let exported = try Data(contentsOf: export)
        let (_, manifest) = try BackupPackage.decode(exported)
        XCTAssertEqual(manifest.archive, loaded)
        XCTAssertEqual(manifest.photos.first?.data, data)
    }

    func testShareImageSizeQRAndNoPrivateMetadata() throws {
        let expected = "https://apps.apple.com/app/id1234567890"
        let stamp = try StampImages.image(photo(), maxPixel: 120)
        let data = try ShareArtwork.render(title: "Sample", caption: "Guest", images: [stamp], storeID: "1234567890")
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, 1080)
        XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int, 1350)
        XCTAssertNil(properties[kCGImagePropertyGPSDictionary])
        XCTAssertNil(properties[kCGImagePropertyIPTCDictionary])
        let exif = properties[kCGImagePropertyExifDictionary] as? [String: Any]
        XCTAssertNil(exif?["DateTimeOriginal"])
        XCTAssertNil(exif?["LensModel"])
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [String: Any]
        XCTAssertNil(tiff?["Make"])
        XCTAssertNil(tiff?["Model"])
        let detector = try XCTUnwrap(CIDetector(ofType: CIDetectorTypeQRCode, context: nil,
                                               options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
        let image = try XCTUnwrap(CIImage(data: data))
        let crop = image.cropped(to: CGRect(x: 830, y: 30, width: 187, height: 199))
        let codes = detector.features(in: crop).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
        XCTAssertTrue(codes.contains(expected))
    }

    private func photo() throws -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 90, height: 120))
        return renderer.pngData { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 90, height: 120))
        }
    }
}
