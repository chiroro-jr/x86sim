// x86Sim: UI tests (XCUITest) driving XCTestDemo.app. testDeliberateUIFailure fails on purpose.
import XCTest

final class XCTestDemoUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testIncrement() {
        let app = XCUIApplication()
        app.launch()
        let label = app.staticTexts["countLabel"]
        XCTAssertTrue(label.waitForExistence(timeout: 30))
        XCTAssertEqual(label.label, "Count: 0")
        app.buttons["incrementButton"].tap()
        app.buttons["incrementButton"].tap()
        XCTAssertEqual(label.label, "Count: 2")
        app.buttons["resetButton"].tap()
        XCTAssertEqual(label.label, "Count: 0")
    }

    func testTypeName() {
        let app = XCUIApplication()
        app.launch()
        let field = app.textFields["nameField"]
        XCTAssertTrue(field.waitForExistence(timeout: 30))
        field.tap()
        field.typeText("Ada")
        XCTAssertEqual(app.staticTexts["greetingLabel"].label, "Hello, Ada!")
    }

    func testDeliberateUIFailure() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["noSuchButton"].waitForExistence(timeout: 2), "deliberate UI failure")
    }
}
