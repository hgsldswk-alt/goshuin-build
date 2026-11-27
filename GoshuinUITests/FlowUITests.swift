import XCTest

final class FlowUITests: XCTestCase {
    private let app = XCUIApplication()

    override func setUpWithError() throws { continueAfterFailure = false }

    private func launch(_ flags: [String] = [], language: String = "ja", reset: Bool = true,
                        routeInput: String? = nil) {
        app.launchArguments = ["-ui-testing", "-AppleLanguages", "(\(language))", "-AppleLocale",
                               ["ja": "ja_JP", "en": "en_US", "zh-Hans": "zh_CN"][language] ?? "ja_JP"]
            + (reset ? ["-reset"] : []) + flags
        if let routeInput { app.launchEnvironment["GOSHUIN_ROUTE_INPUT"] = routeInput }
        app.launch()
    }

    private func visible(_ identifier: String) -> XCUIElement {
        let query = app.buttons.matching(identifier: identifier)
        let deadline = Date().addingTimeInterval(10)
        repeat {
            for index in 0..<query.count {
                let element = query.element(boundBy: index)
                if element.exists && element.isHittable { return element }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        } while Date() < deadline
        XCTFail("not hittable: \(identifier)")
        return query.firstMatch
    }

    private func tap(_ identifier: String) { visible(identifier).tap() }

    private func verifyProgress(_ value: String) {
        let progress = app.staticTexts["route.progress"]
        let expected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", value), object: progress)
        XCTAssertEqual(XCTWaiter.wait(for: [expected], timeout: 8), .completed)
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testCaptureEditSearchAndPersist() {
        launch()
        tap("home.camera")
        tap("camera.shutter")
        tap("home.latest")
        if !app.buttons["detail.edit"].isHittable { app.swipeUp() }
        tap("detail.edit")
        let field = app.textFields["edit.name"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("Kyoto Shrine")
        tap("edit.save")
        tap("sheet.close")
        let search = app.textFields["home.search"]
        search.tap()
        search.typeText("Kyoto")
        XCTAssertTrue(app.buttons["entry.row"].waitForExistence(timeout: 5))
        app.terminate()
        launch(reset: false)
        XCTAssertTrue(app.buttons["home.latest"].waitForExistence(timeout: 8))
    }

    func testUndoAndRecoverRecentlyDeletedPage() {
        launch()
        tap("home.camera")
        tap("camera.shutter")
        tap("home.undo")
        tap("home.settings")
        tap("settings.trash")
        tap("trash.restore")
        let removed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"),
                                                object: app.buttons["trash.restore"])
        XCTAssertEqual(XCTWaiter.wait(for: [removed], timeout: 8), .completed)
    }

    func testDeniedCameraCanUsePhotoImportAndFindUnknownDate() {
        launch(["-camera-denied", "-fixture-photo"])
        tap("home.camera")
        XCTAssertTrue(app.buttons["error.close"].waitForExistence(timeout: 5))
        tap("home.library")
        XCTAssertTrue(app.buttons["home.latest"].waitForExistence(timeout: 8))
        tap("home.date")
        tap("month.unknown")
        XCTAssertTrue(app.buttons["entry.row"].waitForExistence(timeout: 8))
    }

    func testPilgrimageCheckInAndUndoAfterExpiry() {
        launch(["-samples", "-expired"])
        tap("tab.pilgrimage")
        XCTAssertTrue(app.staticTexts["route.progress"].waitForExistence(timeout: 8))
        verifyProgress("4 / 7")
        tap("station.mark")
        verifyProgress("5 / 7")
        tap("route.undo")
        verifyProgress("4 / 7")
        tap("route.current")
        tap("route.edit")
        XCTAssertTrue(app.textFields["route.editName"].waitForExistence(timeout: 8))
        tap("route.saveEdit")
        verifyProgress("4 / 7")
        tap("tab.home")
        tap("home.batch")
        XCTAssertTrue(app.buttons["paywall.restore"].waitForExistence(timeout: 8))
        tap("sheet.close")
        tap("home.settings")
        tap("settings.backup")
        tap("backup.export")
        XCTAssertTrue(app.staticTexts["backup.notice"].waitForExistence(timeout: 8))
    }

    func testRouteImportPreviewThenSave() throws {
        let payload = "{\"version\":1,\"name\":\"Weekend route\",\"stations\":[{\"name\":\"North shrine\",\"region\":\"Kyoto\"}]}"
        let code = Data(payload.utf8).base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
        launch(routeInput: " \n" + "GS1:" + code + "\n ")
        tap("home.importRoute")
        XCTAssertFalse(app.buttons["route.save"].exists)
        tap("route.paste")
        XCTAssertTrue(app.staticTexts["North shrine"].waitForExistence(timeout: 5))
        tap("route.save")
        tap("tab.pilgrimage")
        XCTAssertTrue(app.staticTexts["route.progress"].waitForExistence(timeout: 8))
    }

    func testHomeBackupRestorePreviewsBeforeMerging() {
        launch(["-fixture-backup"])
        tap("home.restore")
        XCTAssertTrue(app.staticTexts["backup.preview"].waitForExistence(timeout: 10))
        tap("backup.confirm")
        XCTAssertTrue(app.staticTexts["backup.notice"].waitForExistence(timeout: 8))
        tap("sheet.close")
        XCTAssertTrue(app.buttons["home.latest"].waitForExistence(timeout: 8))
        app.terminate()
        launch(reset: false)
        XCTAssertTrue(app.buttons["home.latest"].waitForExistence(timeout: 8))
    }

    func testPaidScreenshot() {
        launch(["-paid-mode", "-paywall"], language: "zh-Hans")
        XCTAssertTrue(app.buttons["paywall.buy"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["paywall.restore"].exists)
        shot("paid-01-paywall")
    }

    func testStoreJapanese() { storeScreens("ja") }
    func testStoreEnglish() { storeScreens("en") }
    func testStoreSimplifiedChinese() { storeScreens("zh-Hans") }

    private func storeScreens(_ language: String) {
        launch(["-samples"], language: language)
        XCTAssertTrue(app.buttons["home.latest"].waitForExistence(timeout: 10))
        if app.buttons["trial.hide"].isHittable { tap("trial.hide") }
        shot("store-\(language)-01-home")
        tap("home.date")
        tap("month.2026-11")
        XCTAssertTrue(app.buttons.matching(identifier: "entry.row").firstMatch.waitForExistence(timeout: 8))
        shot("store-\(language)-02-date")

        tap("tab.map")
        tap("map.pin")
        XCTAssertTrue(app.buttons.matching(identifier: "map.entry").firstMatch.waitForExistence(timeout: 8))
        shot("store-\(language)-03-map")
        tap("tab.pilgrimage")
        XCTAssertTrue(app.staticTexts["route.progress"].waitForExistence(timeout: 8))
        shot("store-\(language)-04-pilgrimage")

        for count in 5...7 {
            tap("station.mark")
            verifyProgress("\(count) / 7")
        }
        tap("milestone.card")
        if !app.buttons["share.choose"].isHittable { app.swipeUp() }
        tap("share.choose")
        tap("share.page")
        tap("sheet.close")
        if !app.buttons["share.image"].isHittable { app.swipeDown() }
        let share = visible("share.image")
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: share)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 10), .completed)
        shot("store-\(language)-05-card")
        share.tap()
        XCTAssertTrue(app.staticTexts["share.requested"].waitForExistence(timeout: 8))
    }
}
