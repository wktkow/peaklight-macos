import Darwin
import Foundation

/// Holds Peaklight's per-user process lock for as long as this object lives.
public final class PeaklightInstanceLock {
    public enum AcquisitionError: Swift.Error, Equatable, CustomStringConvertible {
        case alreadyRunning
        case applicationSupportUnavailable
        case directoryCreationFailed(path: String, errno: Int32)
        case directoryOpenFailed(path: String, errno: Int32)
        case unsafeLockDirectory(path: String)
        case directoryPermissionUpdateFailed(path: String, errno: Int32)
        case openFailed(path: String, errno: Int32)
        case unsafeLockFile(path: String)
        case permissionUpdateFailed(path: String, errno: Int32)
        case lockFailed(path: String, errno: Int32)

        public var description: String {
            switch self {
            case .alreadyRunning:
                return "another Peaklight process already holds the instance lock"
            case .applicationSupportUnavailable:
                return "the per-user Application Support directory is unavailable"
            case let .directoryCreationFailed(path, code):
                return "could not create \(path) (errno \(code))"
            case let .directoryOpenFailed(path, code):
                return "could not safely open \(path) (errno \(code))"
            case let .unsafeLockDirectory(path):
                return "refusing unsafe lock directory at \(path)"
            case let .directoryPermissionUpdateFailed(path, code):
                return "could not secure \(path) to mode 0700 (errno \(code))"
            case let .openFailed(path, code):
                return "could not open \(path) (errno \(code))"
            case let .unsafeLockFile(path):
                return "refusing unsafe lock file at \(path)"
            case let .permissionUpdateFailed(path, code):
                return "could not secure \(path) to mode 0600 (errno \(code))"
            case let .lockFailed(path, code):
                return "could not lock \(path) (errno \(code))"
            }
        }
    }

    static let lockDirectoryName = "Peaklight"
    static let lockFileName = "dev.peaklight.Peaklight.instance.lock"

    private var descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit {
        if descriptor >= 0 {
            _ = flock(descriptor, LOCK_UN)
            _ = Darwin.close(descriptor)
        }
    }

    public static func acquire(
        fileManager: FileManager = .default
    ) throws -> PeaklightInstanceLock {
        let applicationSupportDirectory: URL
        do {
            applicationSupportDirectory = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
        } catch {
            throw AcquisitionError.applicationSupportUnavailable
        }

        let directory = lockDirectoryURL(in: applicationSupportDirectory)
        try prepareLockDirectory(at: directory)
        return try acquire(at: lockFileURL(in: directory))
    }

    static func lockDirectoryURL(in applicationSupportDirectory: URL) -> URL {
        applicationSupportDirectory.appendingPathComponent(
            lockDirectoryName,
            isDirectory: true
        )
    }

    static func lockFileURL(in lockDirectory: URL) -> URL {
        lockDirectory.appendingPathComponent(lockFileName, isDirectory: false)
    }

    static func prepareLockDirectory(at directoryURL: URL) throws {
        let path = directoryURL.path
        let createResult = directoryURL.withUnsafeFileSystemRepresentation { directoryPath in
            guard let directoryPath else {
                errno = EINVAL
                return Int32(-1)
            }
            return Darwin.mkdir(directoryPath, mode_t(0o700))
        }
        if createResult != 0, errno != EEXIST {
            throw AcquisitionError.directoryCreationFailed(path: path, errno: errno)
        }

        let directoryDescriptor = directoryURL.withUnsafeFileSystemRepresentation { directoryPath in
            guard let directoryPath else {
                errno = EINVAL
                return Int32(-1)
            }
            return Darwin.open(
                directoryPath,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard directoryDescriptor >= 0 else {
            throw AcquisitionError.directoryOpenFailed(path: path, errno: errno)
        }
        defer { _ = Darwin.close(directoryDescriptor) }

        var directoryStatus = stat()
        guard Darwin.fstat(directoryDescriptor, &directoryStatus) == 0 else {
            throw AcquisitionError.directoryOpenFailed(path: path, errno: errno)
        }
        guard (directoryStatus.st_mode & S_IFMT) == S_IFDIR,
              directoryStatus.st_uid == Darwin.geteuid() else {
            throw AcquisitionError.unsafeLockDirectory(path: path)
        }
        guard Darwin.fchmod(directoryDescriptor, mode_t(0o700)) == 0 else {
            throw AcquisitionError.directoryPermissionUpdateFailed(
                path: path,
                errno: errno
            )
        }
    }

    static func acquire(at lockFileURL: URL) throws -> PeaklightInstanceLock {
        let path = lockFileURL.path
        let descriptor = lockFileURL.withUnsafeFileSystemRepresentation { fileSystemPath in
            guard let fileSystemPath else {
                errno = EINVAL
                return Int32(-1)
            }
            return Darwin.open(
                fileSystemPath,
                O_CREAT | O_RDWR | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC,
                mode_t(S_IRUSR | S_IWUSR)
            )
        }

        guard descriptor >= 0 else {
            throw AcquisitionError.openFailed(path: path, errno: errno)
        }

        var shouldClose = true
        defer {
            if shouldClose {
                _ = Darwin.close(descriptor)
            }
        }

        var fileStatus = stat()
        guard Darwin.fstat(descriptor, &fileStatus) == 0 else {
            throw AcquisitionError.openFailed(path: path, errno: errno)
        }

        guard (fileStatus.st_mode & S_IFMT) == S_IFREG,
              fileStatus.st_uid == Darwin.geteuid(),
              fileStatus.st_nlink == 1 else {
            throw AcquisitionError.unsafeLockFile(path: path)
        }

        let ownerReadWrite = mode_t(S_IRUSR | S_IWUSR)
        guard Darwin.fchmod(descriptor, ownerReadWrite) == 0 else {
            throw AcquisitionError.permissionUpdateFailed(path: path, errno: errno)
        }

        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let lockErrno = errno
            if lockErrno == EWOULDBLOCK {
                throw AcquisitionError.alreadyRunning
            }
            throw AcquisitionError.lockFailed(path: path, errno: lockErrno)
        }

        shouldClose = false
        return PeaklightInstanceLock(descriptor: descriptor)
    }
}
