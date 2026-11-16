import XCTest
@testable import AttentionCore

final class ReceiverLaunchPolicyTests: XCTestCase {
    func testLaunchDateWinsAcrossPIDWrapAndSimultaneousLaunchesAreOrdered() {
        let old = Date(timeIntervalSince1970: 100), new = Date(timeIntervalSince1970: 200)
        XCTAssertTrue(ReceiverLaunchPolicy.isEarlierInstance(pid: 90000, started: old, currentPID: 100, currentStarted: new))
        XCTAssertFalse(ReceiverLaunchPolicy.isEarlierInstance(pid: 100, started: new, currentPID: 90000, currentStarted: old))
        XCTAssertTrue(ReceiverLaunchPolicy.isEarlierInstance(pid: 100, started: old, currentPID: 101, currentStarted: old))
        XCTAssertFalse(ReceiverLaunchPolicy.isEarlierInstance(pid: 100, started: old, currentPID: 100, currentStarted: old))
    }
    func testPlainReopenAndExplicitExperimentsHaveDifferentScopes() {
        XCTAssertFalse(ReceiverLaunchPolicy.isExplicitRun(["app", "--settings"]))
        XCTAssertTrue(ReceiverLaunchPolicy.isExplicitRun(["app", "--data-dir", "/private/test"]))
        XCTAssertTrue(ReceiverLaunchPolicy.isExplicitRun(["app", "--demo"]))
    }
    func testReviewCannotOpenDefaultOrMalformedProfile() {
        let normal = URL(fileURLWithPath: "/private/normal")
        for args in [[String](), ["--settings"], ["--data-dir"], ["--data-dir", "relative"],
                     ["--data-dir", "/private/normal/../normal"], ["--data-dir", "/a", "--data-dir", "/b"],
                     ["--data-dir", "/private/a\nb"]] {
            XCTAssertFalse(ReceiverLaunchPolicy.reviewRunIsIsolated(args, normalRoot: normal))
        }
        XCTAssertTrue(ReceiverLaunchPolicy.reviewRunIsIsolated(["--data-dir", "/private/test"], normalRoot: normal))
        XCTAssertTrue(ReceiverLaunchPolicy.reviewRunIsIsolated(["--render-previews", "/private/images"], normalRoot: normal))
    }
}
