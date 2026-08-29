import Foundation
import XCTest
@testable import PeaklightInstallSupport

final class AtomicAppPublisherTests: XCTestCase {
    func testPublishesIntoAnEmptyDestinationWithExclusiveRename() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let staged = root.appendingPathComponent("staged.app", isDirectory: true)
        let destination = root.appendingPathComponent("installed.app", isDirectory: true)
        try makeBundle(at: staged, marker: "new")

        let result = try AtomicAppPublisher.publish(staged: staged, to: destination)

        XCTAssertEqual(result, .installed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
        XCTAssertEqual(try marker(in: destination), "new")
    }

    func testAtomicallySwapsAnExistingDestination() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let staged = root.appendingPathComponent("staged.app", isDirectory: true)
        let destination = root.appendingPathComponent("installed.app", isDirectory: true)
        try makeBundle(at: staged, marker: "new")
        try makeBundle(at: destination, marker: "old")

        let result = try AtomicAppPublisher.publish(staged: staged, to: destination)

        XCTAssertEqual(result, .replaced)
        XCTAssertEqual(try marker(in: destination), "new")
        XCTAssertEqual(try marker(in: staged), "old")
    }

    func testRejectsSymlinkDestinationWithoutTouchingEitherTree() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let staged = root.appendingPathComponent("staged.app", isDirectory: true)
        let realDestination = root.appendingPathComponent("real.app", isDirectory: true)
        let destination = root.appendingPathComponent("installed.app", isDirectory: true)
        try makeBundle(at: staged, marker: "new")
        try makeBundle(at: realDestination, marker: "old")
        try FileManager.default.createSymbolicLink(
            at: destination,
            withDestinationURL: realDestination
        )

        XCTAssertThrowsError(
            try AtomicAppPublisher.publish(staged: staged, to: destination)
        )
        XCTAssertEqual(try marker(in: staged), "new")
        XCTAssertEqual(try marker(in: realDestination), "old")
    }

    func testRejectsSymlinkedStagedParentWithoutPublishing() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let realParent = root.appendingPathComponent("real-staging", isDirectory: true)
        let linkedParent = root.appendingPathComponent("linked-staging", isDirectory: true)
        let staged = linkedParent.appendingPathComponent("staged.app", isDirectory: true)
        let destination = root.appendingPathComponent("installed.app", isDirectory: true)
        try FileManager.default.createDirectory(at: realParent, withIntermediateDirectories: false)
        try makeBundle(
            at: realParent.appendingPathComponent("staged.app", isDirectory: true),
            marker: "new"
        )
        try FileManager.default.createSymbolicLink(
            at: linkedParent,
            withDestinationURL: realParent
        )

        XCTAssertThrowsError(
            try AtomicAppPublisher.publish(staged: staged, to: destination)
        )
        XCTAssertEqual(
            try marker(in: realParent.appendingPathComponent("staged.app")),
            "new"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testRejectsSymlinkedDestinationParentWithoutPublishing() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let realParent = root.appendingPathComponent("real-install", isDirectory: true)
        let linkedParent = root.appendingPathComponent("linked-install", isDirectory: true)
        let staged = root.appendingPathComponent("staged.app", isDirectory: true)
        let realDestination = realParent.appendingPathComponent("installed.app", isDirectory: true)
        let destination = linkedParent.appendingPathComponent("installed.app", isDirectory: true)
        try FileManager.default.createDirectory(at: realParent, withIntermediateDirectories: false)
        try makeBundle(at: staged, marker: "new")
        try FileManager.default.createSymbolicLink(
            at: linkedParent,
            withDestinationURL: realParent
        )

        XCTAssertThrowsError(
            try AtomicAppPublisher.publish(staged: staged, to: destination)
        )
        XCTAssertEqual(try marker(in: staged), "new")
        XCTAssertFalse(FileManager.default.fileExists(atPath: realDestination.path))
    }

    func testVerificationFailureRestoresExistingDestination() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let staged = root.appendingPathComponent("staged.app", isDirectory: true)
        let destination = root.appendingPathComponent("installed.app", isDirectory: true)
        try makeBundle(at: staged, marker: "new")
        try makeBundle(at: destination, marker: "old")

        XCTAssertThrowsError(
            try AtomicAppPublisher.publishVerified(staged: staged, to: destination) { published in
                XCTAssertEqual(try self.marker(in: published), "new")
                throw VerificationError.rejected
            }
        ) { error in
            guard case AtomicAppPublisher.PublishError.verificationFailed = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertEqual(try marker(in: destination), "old")
        XCTAssertEqual(try marker(in: staged), "new")
    }

    func testVerificationFailureWithdrawsFirstInstall() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let staged = root.appendingPathComponent("staged.app", isDirectory: true)
        let destination = root.appendingPathComponent("installed.app", isDirectory: true)
        try makeBundle(at: staged, marker: "new")

        XCTAssertThrowsError(
            try AtomicAppPublisher.publishVerified(staged: staged, to: destination) { _ in
                throw VerificationError.rejected
            }
        ) { error in
            guard case AtomicAppPublisher.PublishError.verificationFailed = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try marker(in: staged), "new")
    }

    func testPinnedStagingChildTransactionRestoresExistingInstall() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let installDirectory = root.appendingPathComponent("Applications", isDirectory: true)
        let stagingName = ".Peaklight-install.A1B2C3"
        let stagingDirectory = installDirectory.appendingPathComponent(
            stagingName,
            isDirectory: true
        )
        let staged = stagingDirectory.appendingPathComponent("Peaklight.app", isDirectory: true)
        let destination = installDirectory.appendingPathComponent("Peaklight.app", isDirectory: true)
        try FileManager.default.createDirectory(
            at: installDirectory,
            withIntermediateDirectories: false
        )
        try FileManager.default.createDirectory(
            at: stagingDirectory,
            withIntermediateDirectories: false
        )
        try makeBundle(at: staged, marker: "new")
        try makeBundle(at: destination, marker: "old")

        XCTAssertThrowsError(
            try AtomicAppPublisher.publishVerified(
                stagedApplicationName: "Peaklight.app",
                fromStagingDirectoryNamed: stagingName,
                in: installDirectory
            ) { published in
                XCTAssertEqual(try self.marker(in: published), "new")
                throw VerificationError.rejected
            }
        ) { error in
            guard case AtomicAppPublisher.PublishError.verificationFailed = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertEqual(try marker(in: destination), "old")
        XCTAssertEqual(try marker(in: staged), "new")
    }

    func testRollbackRefusesChangedBackupAndPreservesBothTrees() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let staged = root.appendingPathComponent("staged.app", isDirectory: true)
        let destination = root.appendingPathComponent("installed.app", isDirectory: true)
        try makeBundle(at: staged, marker: "new")
        try makeBundle(at: destination, marker: "old")

        XCTAssertThrowsError(
            try AtomicAppPublisher.publishVerified(staged: staged, to: destination) { _ in
                try FileManager.default.removeItem(at: staged)
                try self.makeBundle(at: staged, marker: "intruder")
                throw VerificationError.rejected
            }
        ) { error in
            guard case AtomicAppPublisher.PublishError.rollbackFailed = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertEqual(try marker(in: destination), "new")
        XCTAssertEqual(try marker(in: staged), "intruder")
    }

    func testPinnedDestinationParentReplacementCannotRedirectRollback() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let stagingParent = root.appendingPathComponent("staging", isDirectory: true)
        let installParent = root.appendingPathComponent("install", isDirectory: true)
        let movedInstallParent = root.appendingPathComponent("install-moved", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingParent, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: installParent, withIntermediateDirectories: false)
        let staged = stagingParent.appendingPathComponent("staged.app", isDirectory: true)
        let destination = installParent.appendingPathComponent("installed.app", isDirectory: true)
        try makeBundle(at: staged, marker: "new")
        try makeBundle(at: destination, marker: "old")

        XCTAssertThrowsError(
            try AtomicAppPublisher.publishVerified(staged: staged, to: destination) { _ in
                try FileManager.default.moveItem(at: installParent, to: movedInstallParent)
                try FileManager.default.createDirectory(
                    at: installParent,
                    withIntermediateDirectories: false
                )
                try self.makeBundle(at: destination, marker: "intruder")
                throw VerificationError.rejected
            }
        ) { error in
            guard case AtomicAppPublisher.PublishError.rollbackFailed = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }

        XCTAssertEqual(try marker(in: destination), "intruder")
        XCTAssertEqual(
            try marker(in: movedInstallParent.appendingPathComponent("installed.app")),
            "new"
        )
        XCTAssertEqual(try marker(in: staged), "old")
    }

    private func makeTemporaryDirectory() throws -> URL {
        // macOS exposes its temporary directory through the /var compatibility
        // symlink, which strict RENAME_NOFOLLOW_ANY correctly rejects. Use the
        // same real, per-user hierarchy as the production install transaction.
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                ".Peaklight-AtomicAppPublisherTests-\(UUID().uuidString)"
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        return directory
    }

    private func makeBundle(at url: URL, marker: String) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        try Data(marker.utf8).write(to: url.appendingPathComponent("marker"))
    }

    private func marker(in url: URL) throws -> String {
        try String(contentsOf: url.appendingPathComponent("marker"), encoding: .utf8)
    }

    private enum VerificationError: Error {
        case rejected
    }
}
