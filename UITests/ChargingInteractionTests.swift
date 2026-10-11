import XCTest
import Foundation

/// Exercises the real SwiftUI bindings and @Observable monitor in the app process.
final class ChargingInteractionTests: XCTestCase {
    @MainActor
    func testPredictionTargetsSurviveTapsAndPersist() {
        continueAfterFailure = false
        let app = XCUIApplication()
        let language = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchArguments = language + ["-chargeTarget", "100"]
        app.launch()
        let stepper = app.steppers["prediction.target"]
        XCTAssertTrue(stepper.waitForExistence(timeout: 15))
        if !stepper.isHittable { app.scrollViews.firstMatch.swipeUp() }

        func expectTarget(_ target: Int) {
            let predicate = NSPredicate(format: "value == %@", "\(target)%")
            let expectation = XCTNSPredicateExpectation(predicate: predicate, object: stepper)
            XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed)
            XCTAssertEqual(app.state, .runningForeground, "Target changes must not crash the monitor")
        }
        for target in [80, 90, 100, 80, 100, 90] {
            let button = app.buttons["prediction.target.\(target)"]
            if !button.isHittable { app.scrollViews.firstMatch.swipeUp() }
            button.tap()
            expectTarget(target)
        }
        let increase = stepper.buttons["Increment"]
        let decrease = stepper.buttons["Decrement"]
        XCTAssertTrue(increase.exists && decrease.exists)
        increase.tap(); expectTarget(91)
        decrease.tap(); expectTarget(90)
        app.buttons["prediction.target.100"].tap(); expectTarget(100)
        XCTAssertFalse(increase.isEnabled)
        app.buttons["prediction.target.80"].tap(); expectTarget(80)
        for _ in 0..<30 { decrease.tap() }
        expectTarget(50)
        XCTAssertFalse(decrease.isEnabled)
        app.buttons["prediction.target.90"].tap(); expectTarget(90)

        app.terminate()
        app.launchArguments = language
        app.launch()
        XCTAssertTrue(stepper.waitForExistence(timeout: 15))
        expectTarget(90)
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(stepper.waitForExistence(timeout: 15))
        expectTarget(90)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Prediction controls after foreground resume"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
