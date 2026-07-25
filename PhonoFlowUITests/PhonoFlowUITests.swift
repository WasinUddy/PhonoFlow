import XCTest

@MainActor
final class PhonoFlowUITests: XCTestCase {
    private func configuredApplication() -> XCUIApplication {
        continueAfterFailure = false

        let app = XCUIApplication()
        app.launchArguments += [
            "-hasAskedLaunchAtLogin", "YES",
            "-proMode", "YES",
            "-showAdvancedVisualizations", "NO",
            "-showDiagnostics", "YES",
            "-remoteAccessEnabled", "YES",
            "-phonoflowUITestWindow", "YES",
        ]
        app.launchEnvironment["PHONOFLOW_ACCEPTANCE"] = "1"
        app.launchEnvironment["PHONOFLOW_AUDIO_BACKEND"] = "fake"
        app.launchEnvironment["PHONOFLOW_REMOTE_BIND_HOST"] = "127.0.0.1"
        app.launchEnvironment["PHONOFLOW_REMOTE_PORT"] = "17866"
        app.launchEnvironment["PHONOFLOW_PAIRING_CODE"] = "123456"
        app.launchEnvironment["PHONOFLOW_AUTH_STORE"] = "memory"
        app.launchEnvironment["PHONOFLOW_DISABLE_BONJOUR"] = "1"
        app.launchEnvironment["PHONOFLOW_UI_TEST_WINDOW"] = "1"
        app.launchEnvironment["PHONOFLOW_STATE_DIR"] =
            FileManager.default.temporaryDirectory
            .appendingPathComponent("PhonoFlowUITests-\(UUID().uuidString)", isDirectory: true)
            .path
        return app
    }

    func testFakeScarlettExposesBothStereoInputPairs() throws {
        let app = configuredApplication()
        app.launch()
        defer { app.terminate() }
        try openMenuBarPopover(in: app)

        let inputDevice = app.descendants(matching: .any)["audio.input.device"]
        XCTAssertTrue(
            inputDevice.waitForExistence(timeout: 5),
            "The fake backend should publish a selectable input device."
        )
        XCTAssertTrue(
            stringValue(of: inputDevice).localizedCaseInsensitiveContains("Scarlett"),
            "Acceptance mode should select the deterministic fake Scarlett device."
        )

        let inputRoute = app.descendants(matching: .any)["audio.input.route"]
        XCTAssertTrue(
            inputRoute.waitForExistence(timeout: 5),
            "A four-input device must expose an explicit stereo route selector."
        )
        inputRoute.click()

        let firstPair = app.menuItems
            .matching(NSPredicate(format: "title BEGINSWITH %@", "Inputs 1–2"))
            .firstMatch
        let secondPair = app.menuItems
            .matching(NSPredicate(format: "title BEGINSWITH %@", "Inputs 3–4"))
            .firstMatch
        XCTAssertTrue(firstPair.waitForExistence(timeout: 2))
        XCTAssertTrue(secondPair.waitForExistence(timeout: 2))
        secondPair.click()
        XCTAssertTrue(
            stringValue(of: inputRoute).contains("3–4"),
            "Changing the route must reconcile to the requested channel pair."
        )

        let outputDevice = app.descendants(matching: .any)["audio.output.device"]
        XCTAssertTrue(outputDevice.waitForExistence(timeout: 2))
        XCTAssertEqual(inputDevice.frame.maxX, inputRoute.frame.maxX, accuracy: 2)
        XCTAssertEqual(inputRoute.frame.maxX, outputDevice.frame.maxX, accuracy: 2)
    }

    func testMonitorAndRecordingControlsHaveDeterministicState() throws {
        let app = configuredApplication()
        app.launch()
        defer { app.terminate() }
        try openMenuBarPopover(in: app)

        let monitor = app.descendants(matching: .any)["action.monitor"]
        let record = app.descendants(matching: .any)["action.record"]
        XCTAssertTrue(monitor.waitForExistence(timeout: 5))
        XCTAssertTrue(record.waitForExistence(timeout: 5))
        makeActionControlsVisible(in: app, anchor: monitor)
        XCTAssertTrue(waitForEnabled(monitor))
        XCTAssertTrue(waitForEnabled(record))

        monitor.click()
        XCTAssertTrue(waitForValue("On", in: monitor))

        record.click()
        XCTAssertTrue(waitForValue("On", in: record))
        record.click()
        XCTAssertTrue(waitForValue("Off", in: record))
    }

    func testRemoteAccessSettingsOpenFromKeyboardAndRemainAccessible() throws {
        let app = configuredApplication()
        app.launch()
        defer { app.terminate() }
        try openMenuBarPopover(in: app)

        contentSurface(in: app).typeKey(",", modifierFlags: .command)

        let settingsWindow = app.windows["PhonoFlow Settings"]
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 5))

        let remoteTab = app.tabs["Remote Access"]
        XCTAssertTrue(remoteTab.waitForExistence(timeout: 3))
        remoteTab.click()
        attachScreenshot(named: "Remote Access settings")

        let remoteToggle = app.descendants(matching: .any)["settings.remote.enabled"]
        XCTAssertTrue(remoteToggle.waitForExistence(timeout: 3))
        XCTAssertEqual(stringValue(of: remoteToggle), "1")
    }

    private func openMenuBarPopover(in app: XCUIApplication) throws {
        let acceptanceWindow = app.windows["PhonoFlow Acceptance"]
        if acceptanceWindow.waitForExistence(timeout: 3) {
            assertPopoverLayout(acceptanceWindow)
            attachScreenshot(named: "Menu bar popover")
            return
        }

        let applicationStatusItem = app.menuBars.statusItems["PhonoFlow"]
        if applicationStatusItem.waitForExistence(timeout: 3) {
            clickStatusItem(applicationStatusItem)
            assertPopoverLayout(app.dialogs.firstMatch)
            attachScreenshot(named: "Menu bar popover")
            return
        }

        let systemUIServer = XCUIApplication(bundleIdentifier: "com.apple.systemuiserver")
        let systemStatusItem = systemUIServer.menuBars.statusItems["PhonoFlow"]
        XCTAssertTrue(
            systemStatusItem.waitForExistence(timeout: 5),
            "PhonoFlow should expose a named macOS menu-bar item."
        )
        clickStatusItem(systemStatusItem)
        assertPopoverLayout(app.dialogs.firstMatch)
        attachScreenshot(named: "Menu bar popover")
    }

    private func clickStatusItem(_ statusItem: XCUIElement) {
        if statusItem.isHittable {
            statusItem.click()
            return
        }

        // XCUITest can report a valid menu-bar item as non-hittable when the
        // active menu bar belongs to a display above the primary display.
        // A coordinate click still targets the item's global AppKit frame.
        statusItem.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
        ).click()
    }

    private func assertPopoverLayout(_ popover: XCUIElement) {
        XCTAssertTrue(popover.waitForExistence(timeout: 3))
        XCTAssertTrue(
            waitForPopoverLayout(popover),
            "The menu-bar popover should finish laying out before assertions run."
        )
        XCTAssertEqual(popover.frame.width, 560, accuracy: 2)
        XCTAssertGreaterThanOrEqual(popover.frame.height, 670)
    }

    private func stringValue(of element: XCUIElement) -> String {
        if let value = element.value as? String {
            return value
        }
        return element.value.map(String.init(describing:)) ?? ""
    }

    private func attachScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func makeActionControlsVisible(
        in app: XCUIApplication,
        anchor: XCUIElement
    ) {
        let scrollView = contentSurface(in: app).scrollViews.firstMatch
        for _ in 0..<4 where !anchor.isHittable {
            scrollView.swipeUp()
        }
        XCTAssertTrue(anchor.isHittable)
    }

    private func contentSurface(in app: XCUIApplication) -> XCUIElement {
        let acceptanceWindow = app.windows["PhonoFlow Acceptance"]
        return acceptanceWindow.exists ? acceptanceWindow : app.dialogs.firstMatch
    }

    private func waitForEnabled(
        _ element: XCUIElement,
        timeout: TimeInterval = 5
    ) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == YES AND enabled == YES"),
            object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func waitForValue(
        _ value: String,
        in element: XCUIElement,
        timeout: TimeInterval = 5
    ) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", value),
            object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func waitForPopoverLayout(
        _ popover: XCUIElement,
        timeout: TimeInterval = 3
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let frame = popover.frame
            if frame.width >= 558, frame.height >= 670 {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        } while Date() < deadline
        return false
    }
}
