import Darwin
import Foundation
import XCTest
@testable import PeaklightCore

final class PeaklightInstanceLockTests: XCTestCase {
    func testLockPathIsStableWithinApplicationSupport() {
        let applicationSupportDirectory = URL(
            fileURLWithPath: "/Users/example/Library/Application Support",
            isDirectory: true
        )
        let lockDirectory = PeaklightInstanceLock.lockDirectoryURL(
            in: applicationSupportDirectory
        )

        XCTAssertEqual(
            PeaklightInstanceLock.lockFileURL(in: lockDirectory).path,
            "/Users/example/Library/Application Support/Peaklight/dev.peaklight.Peaklight.instance.lock"
        )
    }

    func testPreparedLockDirectoryHasOwnerOnlyPermissions() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let lockDirectory = temporaryDirectory.appendingPathComponent(
            "Peaklight",
            isDirectory: true
        )

        try PeaklightInstanceLock.prepareLockDirectory(at: lockDirectory)
        var directoryStatus = stat()

        XCTAssertEqual(stat(lockDirectory.path, &directoryStatus), 0)
        XCTAssertEqual(directoryStatus.st_mode & mode_t(0o777), mode_t(0o700))
    }

    func testSecondNonblockingAcquisitionFailsUntilFirstLockIsReleased() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let lockURL = temporaryDirectory.appendingPathComponent("instance.lock")

        var firstLock: PeaklightInstanceLock? = try PeaklightInstanceLock.acquire(at: lockURL)

        try withExtendedLifetime(firstLock) {
            XCTAssertThrowsError(try PeaklightInstanceLock.acquire(at: lockURL)) { error in
                XCTAssertEqual(
                    error as? PeaklightInstanceLock.AcquisitionError,
                    .alreadyRunning
                )
            }
        }

        firstLock = nil
        let replacementLock = try PeaklightInstanceLock.acquire(at: lockURL)
        withExtendedLifetime(replacementLock) {}
    }

    func testCreatedLockFileHasOwnerOnlyReadWritePermissions() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let lockURL = temporaryDirectory.appendingPathComponent("instance.lock")

        let lock = try PeaklightInstanceLock.acquire(at: lockURL)
        var fileStatus = stat()

        XCTAssertEqual(stat(lockURL.path, &fileStatus), 0)
        XCTAssertEqual(fileStatus.st_mode & mode_t(0o777), mode_t(0o600))
        withExtendedLifetime(lock) {}
    }

    func testSymbolicLinkLockPathIsRejectedWithoutTouchingItsTarget() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let targetURL = temporaryDirectory.appendingPathComponent("target")
        let lockURL = temporaryDirectory.appendingPathComponent("instance.lock")
        let originalContents = Data("unchanged".utf8)

        try originalContents.write(to: targetURL)
        try FileManager.default.createSymbolicLink(
            at: lockURL,
            withDestinationURL: targetURL
        )

        XCTAssertThrowsError(try PeaklightInstanceLock.acquire(at: lockURL)) { error in
            guard case let PeaklightInstanceLock.AcquisitionError.openFailed(_, code) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(code, ELOOP)
        }
        XCTAssertEqual(try Data(contentsOf: targetURL), originalContents)
    }

    func testNamedPipeLockPathIsRejectedWithoutBlocking() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let lockURL = temporaryDirectory.appendingPathComponent("instance.lock")
        XCTAssertEqual(mkfifo(lockURL.path, mode_t(0o600)), 0)

        XCTAssertThrowsError(try PeaklightInstanceLock.acquire(at: lockURL)) { error in
            guard case PeaklightInstanceLock.AcquisitionError.unsafeLockFile = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PeaklightInstanceLockTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        return directory
    }
}
