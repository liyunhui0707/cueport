import XCTest
@testable import AttentionCore

final class RuntimeDiagnosticsTests: XCTestCase {
    func testFileIdentityReadsOnlyBoundedMachOHeaderAndRejectsTruncation() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("aar-header-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let valid = image(3)
        try (valid + Data(repeating: 0xff, count: 2_000_000)).write(to: file)
        XCTAssertEqual(MachOBuildIdentity.fileUUID(file), MachOBuildIdentity.uuid(in: valid))
        try valid.dropLast().write(to: file)
        XCTAssertNil(MachOBuildIdentity.fileUUID(file))
        var oversized = valid
        oversized[20] = 0xff; oversized[21] = 0xff; oversized[22] = 0xff; oversized[23] = 0x7f
        try oversized.write(to: file)
        XCTAssertNil(MachOBuildIdentity.fileUUID(file))
    }
    func image(_ byte: UInt8) -> Data {
        var data = Data([0xcf, 0xfa, 0xed, 0xfe] + Array(repeating: 0, count: 28))
        data[16] = 1; data[20] = 24
        data.append(contentsOf: [0x1b, 0, 0, 0, 24, 0, 0, 0] + Array(repeating: byte, count: 16))
        return data
    }
    func testBuildIdentityDetectsAnUpdatedDiskImageWithoutRelabelingTheRunningImage() throws {
        let running = try XCTUnwrap(MachOBuildIdentity.uuid(in: image(1)))
        let updated = try XCTUnwrap(MachOBuildIdentity.uuid(in: image(2)))
        XCTAssertEqual(BuildStatus(running: running, onDisk: running).status, .current)
        XCTAssertEqual(BuildStatus(running: running, onDisk: updated).status, .restartNeeded)
        XCTAssertEqual(BuildStatus(running: running, onDisk: updated).running, running)
        XCTAssertEqual(BuildStatus(running: nil, onDisk: updated).status, .unverified)
        XCTAssertEqual(BuildStatus(running: running, onDisk: nil).status, .unverified)
    }
    func testMalformedTruncatedOrDuplicateMachOUUIDsAreUnverified() {
        let valid = image(1)
        for n in [0, 4, 28, 32, 40, 55] { XCTAssertNil(MachOBuildIdentity.uuid(in: valid.prefix(n))) }
        var wrongMagic = valid; wrongMagic[0] = 0
        XCTAssertNil(MachOBuildIdentity.uuid(in: wrongMagic))
        var overflow = valid; overflow[20] = 255; overflow[21] = 255
        XCTAssertNil(MachOBuildIdentity.uuid(in: overflow))
        var undersized = valid; undersized[36] = 4
        XCTAssertNil(MachOBuildIdentity.uuid(in: undersized))
        var duplicate = valid; duplicate[16] = 2; duplicate[20] = 48
        duplicate.append(valid.suffix(24))
        XCTAssertNil(MachOBuildIdentity.uuid(in: duplicate))
        XCTAssertNil(MachOBuildIdentity.uuid(in: image(0)))
    }
}
