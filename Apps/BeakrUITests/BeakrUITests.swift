import XCTest

final class BeakrUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testMailStyleShellProvidesToolbarWindowsAndDialogs() throws {
        let app = XCUIApplication()
        app.launch()

        let composeButton = app.buttons["Compose"]
        let contactsButton = app.buttons["Contacts"]
        let networksButton = app.buttons["Networks"]
        let shareNetworkButton = app.buttons["Share Network"]
        let deviceButton = app.buttons["Device"]
        let mailboxActionsButton = app.menuButtons["Mailbox Actions"]

        XCTAssertTrue(composeButton.waitForExistence(timeout: 5))
        XCTAssertTrue(contactsButton.exists)
        XCTAssertTrue(networksButton.exists)
        XCTAssertTrue(shareNetworkButton.exists)
        XCTAssertTrue(deviceButton.exists)
        XCTAssertTrue(mailboxActionsButton.exists)

        networksButton.click()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 2))
        app.typeKey("w", modifierFlags: .command)

        contactsButton.click()
        XCTAssertTrue(app.staticTexts["Contacts Management"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["Done"].exists)
    }

    @MainActor
    func testLaunchPerformance() throws {
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
