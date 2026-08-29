import Darwin
import Foundation

public enum AtomicAppPublisher {
    public enum PublishResult: Equatable {
        case installed
        case replaced
    }

    public enum PublishError: Swift.Error, CustomStringConvertible {
        case identicalPaths(String)
        case unsafeDirectory(role: String, path: String)
        case unsafeLeaf(role: String, path: String)
        case inspectionFailed(role: String, path: String, errno: Int32)
        case stateChanged(role: String, path: String)
        case renameFailed(source: String, destination: String, errno: Int32)
        case verificationFailed(destination: String, reason: String)
        case rollbackFailed(
            destination: String,
            verificationReason: String,
            rollbackReason: String
        )

        public var description: String {
            switch self {
            case let .identicalPaths(path):
                return "source and destination are identical: \(path)"
            case let .unsafeDirectory(role, path):
                return "\(role) is not a safe, current-user directory: \(path)"
            case let .unsafeLeaf(role, path):
                return "\(role) is not one safe path component: \(path)"
            case let .inspectionFailed(role, path, code):
                return "could not inspect \(role) at \(path) (errno \(code))"
            case let .stateChanged(role, path):
                return "\(role) changed during the install transaction at \(path)"
            case let .renameFailed(source, destination, code):
                return "could not atomically publish \(source) at \(destination) (errno \(code))"
            case let .verificationFailed(destination, reason):
                return "published app at \(destination) failed verification and was rolled back: \(reason)"
            case let .rollbackFailed(destination, verificationReason, rollbackReason):
                return "published app at \(destination) failed verification (\(verificationReason)); rollback also failed (\(rollbackReason))"
            }
        }
    }

    private struct FileIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
    }

    private final class DirectoryHandle {
        let descriptor: Int32
        let path: String
        let identity: FileIdentity

        init(descriptor: Int32, path: String, identity: FileIdentity) {
            self.descriptor = descriptor
            self.path = path
            self.identity = identity
        }

        deinit {
            _ = Darwin.close(descriptor)
        }
    }

    private struct Endpoint {
        let directory: DirectoryHandle
        let leaf: String
        let fullPath: String
        let role: String
    }

    private struct PublishedState {
        let result: PublishResult
        let source: Endpoint
        let target: Endpoint
        let newIdentity: FileIdentity
        let oldIdentity: FileIdentity?
    }

    /// Publishes a staged app using one atomic, descriptor-relative filesystem
    /// operation. Retained directory descriptors prevent a concurrent pathname
    /// replacement from redirecting either endpoint.
    public static func publish(
        staged: URL,
        to destination: URL
    ) throws -> PublishResult {
        try performPublish(staged: staged, to: destination).result
    }

    /// Publishes and verifies while the caller continues to hold its external
    /// transaction lock. A failed verification restores the prior namespace
    /// state when its recorded identities are still present. If any identity
    /// changed, rollback fails closed so the caller can preserve recovery data.
    @discardableResult
    public static func publishVerified(
        staged: URL,
        to destination: URL,
        verify: (URL) throws -> Void
    ) throws -> PublishResult {
        let state = try performPublish(staged: staged, to: destination)
        return try finishVerifiedPublish(
            state,
            destination: destination,
            verify: verify
        )
    }

    /// Installer-specialized form: opens the canonical install directory once,
    /// then opens the staging transaction directory relative to that pinned
    /// descriptor. This proves the staging directory is a direct child of the
    /// exact install directory used by descriptor-relative publication.
    @discardableResult
    public static func publishVerified(
        stagedApplicationName: String,
        fromStagingDirectoryNamed stagingDirectoryName: String,
        in installDirectory: URL,
        verify: (URL) throws -> Void
    ) throws -> PublishResult {
        try requireSafeComponent(
            stagedApplicationName,
            role: "staged application name"
        )
        try requireSafeComponent(
            stagingDirectoryName,
            role: "staging transaction directory name"
        )

        let installPath = lexicalPath(installDirectory)
        let installHandle = try openDirectory(
            installPath,
            role: "install directory"
        )
        let stagingHandle = try openDirectory(
            named: stagingDirectoryName,
            relativeTo: installHandle,
            role: "staging transaction directory"
        )
        let stagingPath = (installPath as NSString)
            .appendingPathComponent(stagingDirectoryName)
        let source = Endpoint(
            directory: stagingHandle,
            leaf: stagedApplicationName,
            fullPath: (stagingPath as NSString)
                .appendingPathComponent(stagedApplicationName),
            role: "staged app"
        )
        let target = Endpoint(
            directory: installHandle,
            leaf: stagedApplicationName,
            fullPath: (installPath as NSString)
                .appendingPathComponent(stagedApplicationName),
            role: "install destination"
        )
        let destination = installDirectory.appendingPathComponent(
            stagedApplicationName,
            isDirectory: true
        )
        let state = try performPublish(from: source, to: target)
        return try finishVerifiedPublish(
            state,
            destination: destination,
            verify: verify
        )
    }

    private static func finishVerifiedPublish(
        _ state: PublishedState,
        destination: URL,
        verify: (URL) throws -> Void
    ) throws -> PublishResult {

        do {
            try verify(destination)
            try requirePublishedState(state)
            return state.result
        } catch {
            let verificationReason = String(describing: error)
            do {
                try rollback(state)
            } catch {
                throw PublishError.rollbackFailed(
                    destination: destination.path,
                    verificationReason: verificationReason,
                    rollbackReason: String(describing: error)
                )
            }

            throw PublishError.verificationFailed(
                destination: destination.path,
                reason: verificationReason
            )
        }
    }

    private static func performPublish(
        staged: URL,
        to destination: URL
    ) throws -> PublishedState {
        let source = try endpoint(for: staged, role: "staged app")
        let target = try endpoint(for: destination, role: "install destination")
        return try performPublish(from: source, to: target)
    }

    private static func performPublish(
        from source: Endpoint,
        to target: Endpoint
    ) throws -> PublishedState {
        guard source.fullPath != target.fullPath else {
            throw PublishError.identicalPaths(source.fullPath)
        }
        guard source.directory.identity.device == target.directory.identity.device else {
            throw PublishError.stateChanged(
                role: "transaction directories are on different filesystems",
                path: "\(source.directory.path) -> \(target.directory.path)"
            )
        }

        try requirePinnedDirectories(source, target)
        let newIdentity = try requireRealDirectory(source)
        let oldIdentity = try inspectDestination(target)
        let operation = oldIdentity == nil ? RENAME_EXCL : RENAME_SWAP

        try rename(
            from: source,
            to: target,
            flags: UInt32(operation | RENAME_NOFOLLOW_ANY)
        )

        let state = PublishedState(
            result: oldIdentity == nil ? .installed : .replaced,
            source: source,
            target: target,
            newIdentity: newIdentity,
            oldIdentity: oldIdentity
        )
        try requirePublishedState(state)
        return state
    }

    private static func rollback(_ state: PublishedState) throws {
        try requirePublishedState(state)

        switch state.result {
        case .replaced:
            try rename(
                from: state.source,
                to: state.target,
                flags: UInt32(RENAME_SWAP | RENAME_NOFOLLOW_ANY)
            )
            try requireIdentity(
                state.oldIdentity,
                at: state.target,
                role: "restored app"
            )
            try requireIdentity(
                state.newIdentity,
                at: state.source,
                role: "rolled-back staged app"
            )
        case .installed:
            try rename(
                from: state.target,
                to: state.source,
                flags: UInt32(RENAME_EXCL | RENAME_NOFOLLOW_ANY)
            )
            try requireAbsent(
                state.target,
                role: "withdrawn install destination"
            )
            try requireIdentity(
                state.newIdentity,
                at: state.source,
                role: "rolled-back staged app"
            )
        }

        try requirePinnedDirectories(state.source, state.target)
    }

    private static func requirePublishedState(_ state: PublishedState) throws {
        try requirePinnedDirectories(state.source, state.target)
        try requireIdentity(
            state.newIdentity,
            at: state.target,
            role: "published app"
        )
        if let oldIdentity = state.oldIdentity {
            try requireIdentity(
                oldIdentity,
                at: state.source,
                role: "prior app backup"
            )
        } else {
            try requireAbsent(
                state.source,
                role: "staged app after publication"
            )
        }
    }

    private static func endpoint(for url: URL, role: String) throws -> Endpoint {
        let fullPath = lexicalPath(url)
        let path = fullPath as NSString
        let leaf = path.lastPathComponent
        let parent = path.deletingLastPathComponent

        guard fullPath.hasPrefix("/"),
              !parent.isEmpty,
              !leaf.isEmpty,
              leaf != ".",
              leaf != "..",
              !leaf.contains("/") else {
            throw PublishError.unsafeLeaf(role: role, path: fullPath)
        }

        return Endpoint(
            directory: try openDirectory(parent, role: "\(role) parent"),
            leaf: leaf,
            fullPath: fullPath,
            role: role
        )
    }

    private static func openDirectory(
        _ path: String,
        role: String
    ) throws -> DirectoryHandle {
        let descriptor = path.withCString { fileSystemPath in
            Darwin.open(
                fileSystemPath,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC
            )
        }
        let openErrno = errno
        guard descriptor >= 0 else {
            throw PublishError.inspectionFailed(
                role: role,
                path: path,
                errno: openErrno
            )
        }

        var shouldClose = true
        defer {
            if shouldClose {
                _ = Darwin.close(descriptor)
            }
        }

        var directoryStatus = stat()
        let inspectResult = Darwin.fstat(descriptor, &directoryStatus)
        let inspectErrno = errno
        guard inspectResult == 0 else {
            throw PublishError.inspectionFailed(
                role: role,
                path: path,
                errno: inspectErrno
            )
        }
        guard (directoryStatus.st_mode & S_IFMT) == S_IFDIR,
              directoryStatus.st_uid == Darwin.geteuid() else {
            throw PublishError.unsafeDirectory(role: role, path: path)
        }

        shouldClose = false
        return DirectoryHandle(
            descriptor: descriptor,
            path: path,
            identity: identity(directoryStatus)
        )
    }

    private static func openDirectory(
        named name: String,
        relativeTo parent: DirectoryHandle,
        role: String
    ) throws -> DirectoryHandle {
        try requireSafeComponent(name, role: role)
        try requireDirectoryStillNamed(parent, role: "install directory")
        let path = (parent.path as NSString).appendingPathComponent(name)
        let descriptor = name.withCString { fileSystemName in
            Darwin.openat(
                parent.descriptor,
                fileSystemName,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        let openErrno = errno
        guard descriptor >= 0 else {
            throw PublishError.inspectionFailed(
                role: role,
                path: path,
                errno: openErrno
            )
        }

        var shouldClose = true
        defer {
            if shouldClose {
                _ = Darwin.close(descriptor)
            }
        }
        var directoryStatus = stat()
        let inspectResult = Darwin.fstat(descriptor, &directoryStatus)
        let inspectErrno = errno
        guard inspectResult == 0 else {
            throw PublishError.inspectionFailed(
                role: role,
                path: path,
                errno: inspectErrno
            )
        }
        guard (directoryStatus.st_mode & S_IFMT) == S_IFDIR,
              directoryStatus.st_uid == Darwin.geteuid(),
              directoryStatus.st_dev == parent.identity.device else {
            throw PublishError.unsafeDirectory(role: role, path: path)
        }

        shouldClose = false
        return DirectoryHandle(
            descriptor: descriptor,
            path: path,
            identity: identity(directoryStatus)
        )
    }

    private static func requirePinnedDirectories(
        _ source: Endpoint,
        _ target: Endpoint
    ) throws {
        try requireDirectoryStillNamed(source.directory, role: "staged app parent")
        try requireDirectoryStillNamed(target.directory, role: "install destination parent")
    }

    private static func requireDirectoryStillNamed(
        _ directory: DirectoryHandle,
        role: String
    ) throws {
        var pathStatus = stat()
        let result = Darwin.lstat(directory.path, &pathStatus)
        let inspectionErrno = errno
        guard result == 0 else {
            throw PublishError.inspectionFailed(
                role: role,
                path: directory.path,
                errno: inspectionErrno
            )
        }
        guard (pathStatus.st_mode & S_IFMT) == S_IFDIR,
              identity(pathStatus) == directory.identity else {
            throw PublishError.stateChanged(role: role, path: directory.path)
        }
    }

    private static func inspectDestination(
        _ endpoint: Endpoint
    ) throws -> FileIdentity? {
        var fileStatus = stat()
        let result = endpoint.leaf.withCString { leaf in
            Darwin.fstatat(
                endpoint.directory.descriptor,
                leaf,
                &fileStatus,
                AT_SYMLINK_NOFOLLOW
            )
        }
        let inspectionErrno = errno
        if result == 0 {
            guard (fileStatus.st_mode & S_IFMT) == S_IFDIR,
                  fileStatus.st_uid == Darwin.geteuid() else {
                throw PublishError.unsafeDirectory(
                    role: endpoint.role,
                    path: endpoint.fullPath
                )
            }
            return identity(fileStatus)
        }
        if inspectionErrno == ENOENT {
            return nil
        }
        throw PublishError.inspectionFailed(
            role: endpoint.role,
            path: endpoint.fullPath,
            errno: inspectionErrno
        )
    }

    private static func requireRealDirectory(
        _ endpoint: Endpoint
    ) throws -> FileIdentity {
        var fileStatus = stat()
        let result = endpoint.leaf.withCString { leaf in
            Darwin.fstatat(
                endpoint.directory.descriptor,
                leaf,
                &fileStatus,
                AT_SYMLINK_NOFOLLOW
            )
        }
        let inspectionErrno = errno
        guard result == 0 else {
            throw PublishError.inspectionFailed(
                role: endpoint.role,
                path: endpoint.fullPath,
                errno: inspectionErrno
            )
        }
        guard (fileStatus.st_mode & S_IFMT) == S_IFDIR,
              fileStatus.st_uid == Darwin.geteuid() else {
            throw PublishError.unsafeDirectory(
                role: endpoint.role,
                path: endpoint.fullPath
            )
        }
        return identity(fileStatus)
    }

    private static func requireIdentity(
        _ expected: FileIdentity?,
        at endpoint: Endpoint,
        role: String
    ) throws {
        guard let expected else {
            throw PublishError.stateChanged(role: role, path: endpoint.fullPath)
        }
        var fileStatus = stat()
        let result = endpoint.leaf.withCString { leaf in
            Darwin.fstatat(
                endpoint.directory.descriptor,
                leaf,
                &fileStatus,
                AT_SYMLINK_NOFOLLOW
            )
        }
        let inspectionErrno = errno
        guard result == 0 else {
            throw PublishError.inspectionFailed(
                role: role,
                path: endpoint.fullPath,
                errno: inspectionErrno
            )
        }
        guard (fileStatus.st_mode & S_IFMT) == S_IFDIR,
              identity(fileStatus) == expected else {
            throw PublishError.stateChanged(role: role, path: endpoint.fullPath)
        }
    }

    private static func requireAbsent(
        _ endpoint: Endpoint,
        role: String
    ) throws {
        var fileStatus = stat()
        let result = endpoint.leaf.withCString { leaf in
            Darwin.fstatat(
                endpoint.directory.descriptor,
                leaf,
                &fileStatus,
                AT_SYMLINK_NOFOLLOW
            )
        }
        if result == 0 {
            throw PublishError.stateChanged(role: role, path: endpoint.fullPath)
        }
        let inspectionErrno = errno
        guard inspectionErrno == ENOENT else {
            throw PublishError.inspectionFailed(
                role: role,
                path: endpoint.fullPath,
                errno: inspectionErrno
            )
        }
    }

    private static func rename(
        from source: Endpoint,
        to target: Endpoint,
        flags: UInt32
    ) throws {
        let result = source.leaf.withCString { sourceLeaf in
            target.leaf.withCString { targetLeaf in
                renameatx_np(
                    source.directory.descriptor,
                    sourceLeaf,
                    target.directory.descriptor,
                    targetLeaf,
                    flags
                )
            }
        }
        let renameErrno = errno
        guard result == 0 else {
            throw PublishError.renameFailed(
                source: source.fullPath,
                destination: target.fullPath,
                errno: renameErrno
            )
        }
    }

    private static func lexicalPath(_ url: URL) -> String {
        // NSString normalization removes redundant separators and dot
        // components without resolving symlinks. URL.standardizedFileURL must
        // not be used because Foundation can hide /private/var behind /var.
        (url.path as NSString).standardizingPath
    }

    private static func requireSafeComponent(
        _ component: String,
        role: String
    ) throws {
        guard !component.isEmpty,
              component != ".",
              component != "..",
              !component.contains("/") else {
            throw PublishError.unsafeLeaf(role: role, path: component)
        }
    }

    private static func identity(_ status: stat) -> FileIdentity {
        FileIdentity(device: status.st_dev, inode: status.st_ino)
    }
}
