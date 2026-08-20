import XCTest

final class BLEDiscoveryUITests: XCTestCase {
    func testFindRecorderShowsImmediateBluetoothFeedback() {
        let app = XCUIApplication()
        app.launchArguments = ["--initial-tab", "device"]
        app.launch()

        let findButton = app.buttons["Find Recorder"]
        XCTAssertTrue(findButton.waitForExistence(timeout: 5))
        findButton.tap()

        let visibleFeedback = [
            app.buttons["Searching..."],
            app.staticTexts["Bluetooth Low Energy is not supported on this device."],
            app.staticTexts["Turn on Bluetooth to find the recorder."],
            app.staticTexts["Allow Bluetooth for Dawn Recorder in iPhone Settings."],
            app.staticTexts["Open iPhone Settings, allow Bluetooth for Dawn Recorder, and try again."]
        ]

        let deadline = Date().addingTimeInterval(6)
        while Date() < deadline, !visibleFeedback.contains(where: \.exists) {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }

        XCTAssertTrue(
            visibleFeedback.contains(where: \.exists),
            "Find Recorder must immediately expose scanning or a specific Bluetooth error."
        )
    }
}
