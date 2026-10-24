import XCTest
@testable import FACore

final class DeviceIdentityTests: XCTestCase {
    func testNoStoredIDCreatesIDAndStoresHash() {
        let r = DeviceIdentity.resolve(storedID: nil, storedMachineHash: nil, currentMachineHash: "h1")
        XCTAssertFalse(r.id.isEmpty)
        XCTAssertEqual(r.id, r.id.lowercased())
        XCTAssertEqual(r.machineHash, "h1")
    }

    func testNoStoredHashKeepsIDAndStoresHash() {
        let r = DeviceIdentity.resolve(storedID: "abc", storedMachineHash: nil, currentMachineHash: "h1")
        XCTAssertEqual(r.id, "abc")
        XCTAssertEqual(r.machineHash, "h1")
    }

    func testMatchingHashKeepsID() {
        let r = DeviceIdentity.resolve(storedID: "abc", storedMachineHash: "h1", currentMachineHash: "h1")
        XCTAssertEqual(r.id, "abc")
        XCTAssertEqual(r.machineHash, "h1")
    }

    func testDifferentHashCreatesNewID() {
        let r = DeviceIdentity.resolve(storedID: "abc", storedMachineHash: "h1", currentMachineHash: "h2")
        XCTAssertNotEqual(r.id, "abc")
        XCTAssertEqual(r.id, r.id.lowercased())
        XCTAssertEqual(r.machineHash, "h2")
    }

    func testUnreadableHashKeepsEverything() {
        let r = DeviceIdentity.resolve(storedID: "abc", storedMachineHash: "h1", currentMachineHash: nil)
        XCTAssertEqual(r.id, "abc")
        XCTAssertEqual(r.machineHash, "h1")
    }
}
