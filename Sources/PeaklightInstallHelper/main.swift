import Darwin
import Foundation
import PeaklightCore
import PeaklightInstallSupport
import Security

private let productName = "Peaklight"
private let bundleIdentifier = "dev.peaklight.Peaklight"

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("PeaklightInstallHelper: \(message)\n".utf8))
    Darwin.exit(EXIT_FAILURE)
}

private enum BundleValidationError: Error, CustomStringConvertible {
    case unsafeItem(role: String, path: String)
    case unreadablePropertyList(path: String)
    case unexpectedIdentifier(String?)
    case unexpectedExecutable(String?)
    case securityValidation(operation: String, status: OSStatus, detail: String?)

    var description: String {
        switch self {
        case let .unsafeItem(role, path):
            return "\(role) is missing, symlinked, or has the wrong type at \(path)"
        case let .unreadablePropertyList(path):
            return "could not read a valid property list at \(path)"
        case let .unexpectedIdentifier(identifier):
            return "unexpected bundle identifier \(identifier ?? "<missing>")"
        case let .unexpectedExecutable(executable):
            return "unexpected bundle executable \(executable ?? "<missing>")"
        case let .securityValidation(operation, status, detail):
            let suffix = detail.map { ": \($0)" } ?? ""
            return "\(operation) failed with Security status \(status)\(suffix)"
        }
    }
}

private func requireItem(
    at url: URL,
    role: String,
    type: mode_t
) throws {
    var itemStatus = stat()
    let result = Darwin.lstat(url.path, &itemStatus)
    guard result == 0, (itemStatus.st_mode & S_IFMT) == type else {
        throw BundleValidationError.unsafeItem(role: role, path: url.path)
    }
}

private func verifyPublishedBundle(at app: URL) throws {
    try requireItem(at: app, role: "published app", type: S_IFDIR)

    let infoPlist = app.appendingPathComponent("Contents/Info.plist")
    try requireItem(at: infoPlist, role: "published Info.plist", type: S_IFREG)
    let plistData: Data
    do {
        plistData = try Data(contentsOf: infoPlist, options: .mappedIfSafe)
    } catch {
        throw BundleValidationError.unreadablePropertyList(path: infoPlist.path)
    }
    guard let plist = try? PropertyListSerialization.propertyList(
        from: plistData,
        options: [],
        format: nil
    ) as? [String: Any] else {
        throw BundleValidationError.unreadablePropertyList(path: infoPlist.path)
    }
    let identifier = plist["CFBundleIdentifier"] as? String
    guard identifier == bundleIdentifier else {
        throw BundleValidationError.unexpectedIdentifier(identifier)
    }
    let executableName = plist["CFBundleExecutable"] as? String
    guard executableName == productName else {
        throw BundleValidationError.unexpectedExecutable(executableName)
    }

    let executable = app.appendingPathComponent("Contents/MacOS/\(productName)")
    try requireItem(at: executable, role: "published executable", type: S_IFREG)
    guard FileManager.default.isExecutableFile(atPath: executable.path) else {
        throw BundleValidationError.unsafeItem(
            role: "published executable",
            path: executable.path
        )
    }

    var staticCode: SecStaticCode?
    let createStatus = SecStaticCodeCreateWithPath(
        app as CFURL,
        SecCSFlags(),
        &staticCode
    )
    guard createStatus == errSecSuccess, let staticCode else {
        throw BundleValidationError.securityValidation(
            operation: "creating static code",
            status: createStatus,
            detail: nil
        )
    }

    var requirement: SecRequirement?
    let requirementStatus = SecRequirementCreateWithString(
        "identifier \"\(bundleIdentifier)\"" as CFString,
        SecCSFlags(),
        &requirement
    )
    guard requirementStatus == errSecSuccess, let requirement else {
        throw BundleValidationError.securityValidation(
            operation: "creating bundle requirement",
            status: requirementStatus,
            detail: nil
        )
    }

    let validationFlags = SecCSFlags(
        rawValue: kSecCSStrictValidate
            | kSecCSCheckAllArchitectures
            | kSecCSCheckNestedCode
            | kSecCSRestrictSymlinks
            | kSecCSRestrictToAppLike
    )
    var validationError: Unmanaged<CFError>?
    let validationStatus = SecStaticCodeCheckValidityWithErrors(
        staticCode,
        validationFlags,
        requirement,
        &validationError
    )
    let validationDetail = validationError?
        .takeRetainedValue()
        .localizedDescription
    guard validationStatus == errSecSuccess else {
        throw BundleValidationError.securityValidation(
            operation: "validating the published code signature",
            status: validationStatus,
            detail: validationDetail
        )
    }
}

let fileManager = FileManager.default
let installDirectory = fileManager.homeDirectoryForCurrentUser
    .appendingPathComponent("Applications", isDirectory: true)
let destination = installDirectory
    .appendingPathComponent("\(productName).app", isDirectory: true)

if CommandLine.arguments.count == 2,
   CommandLine.arguments[1] == "--print-install-directory" {
    print(installDirectory.path)
    Darwin.exit(EXIT_SUCCESS)
}

guard CommandLine.arguments.count == 2 else {
    fail("expected one staging transaction directory name")
}

let stagingDirectoryName = CommandLine.arguments[1]
let stagingPrefix = ".Peaklight-install."
let stagingSuffix = stagingDirectoryName.dropFirst(stagingPrefix.count)
guard stagingDirectoryName.hasPrefix(stagingPrefix),
      !stagingSuffix.isEmpty,
      stagingSuffix.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }),
      !stagingDirectoryName.contains("/") else {
    fail("invalid staging transaction directory name")
}

do {
    let instanceLock = try PeaklightInstanceLock.acquire()
    try withExtendedLifetime(instanceLock) {
        _ = try AtomicAppPublisher.publishVerified(
            stagedApplicationName: "\(productName).app",
            fromStagingDirectoryNamed: stagingDirectoryName,
            in: installDirectory,
            verify: verifyPublishedBundle
        )
    }
    print(destination.path)
} catch PeaklightInstanceLock.AcquisitionError.alreadyRunning {
    fail("Peaklight is running or another install transaction is active")
} catch {
    fail(String(describing: error))
}
