//
//  DownloadedFile.swift
//  swift-networking
//
//  SPDX-License-Identifier: MIT
//

import Foundation
import Synchronization

/// Tracks the current location and cleanup responsibility for a completed download.
///
/// The package-internal URL lets authentication and validation callbacks inspect the file without
/// transferring ownership. Explicit transfers update the current URL and cleanup responsibility
/// together so an old path is never removed after it has been handed to another owner.
package final class DownloadedFileStorage: Sendable {
    private struct State: Sendable {
        var currentURL: URL
        var cleanupURL: URL?
    }

    private let state: Mutex<State>

    private init(url: URL) {
        state = Mutex(State(currentURL: url, cleanupURL: url))
    }

    /// The current location for internal response processing without transferring ownership.
    package var url: URL {
        state.withLock(\.currentURL)
    }

    package static func adopt(_ foundationURL: URL) throws -> Self {
        let ownedURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "swift-networking-download-\(UUID().uuidString)",
        )
        try FileManager.default.moveItem(at: foundationURL, to: ownedURL)
        return Self(url: ownedURL)
    }

    /// Permanently transfers URL cleanup responsibility to the caller.
    package func transferURLToCaller() -> URL {
        state.withLock { current in
            current.cleanupURL = nil
            return current.currentURL
        }
    }

    /// Moves the file for a successful response to its selected final destination.
    package func finalize(to destination: URL, collisionPolicy: DownloadCollisionPolicy) throws {
        try transfer(to: destination, collisionPolicy: collisionPolicy, failure: .finalization)
    }

    /// Moves the file to a caller-selected destination.
    package func move(to destination: URL, collisionPolicy: DownloadCollisionPolicy) throws {
        try transfer(to: destination, collisionPolicy: collisionPolicy, failure: .move)
    }

    /// Removes the current file, keeping cleanup disarmed if the path is already absent.
    package func remove() throws {
        try state.withLock { current in
            let url = current.currentURL
            do {
                try FileManager.default.removeItem(at: url)
                current.cleanupURL = nil
            } catch {
                guard Self.isMissingFileError(error) else {
                    throw DownloadFileError.removeFailed(url: url, underlyingError: error)
                }

                current.cleanupURL = nil
            }
        }
    }

    /// Removes the library-owned file and retries automatically if a transient failure leaves it.
    package func discard() {
        state.withLock { current in
            guard let cleanupURL = current.cleanupURL else {
                return
            }

            do {
                try FileManager.default.removeItem(at: cleanupURL)
                current.cleanupURL = nil
            } catch {
                if Self.isMissingFileError(error) {
                    current.cleanupURL = nil
                }
            }
        }
    }

    private enum TransferFailure {
        case finalization
        case move
    }

    private func transfer(
        to destination: URL,
        collisionPolicy: DownloadCollisionPolicy,
        failure: TransferFailure,
    ) throws {
        try state.withLock { current in
            let source = current.currentURL
            do {
                if Self.isSameFileLocation(source, destination) {
                    current.currentURL = destination
                    current.cleanupURL = nil
                    return
                }

                try Self.moveFile(from: source, to: destination, collisionPolicy: collisionPolicy)
                current.currentURL = destination
                current.cleanupURL = nil
            } catch {
                switch failure {
                case .finalization:
                    throw DownloadFileError.finalizationFailed(
                        source: source,
                        destination: destination,
                        underlyingError: error,
                    )
                case .move:
                    throw DownloadFileError.moveFailed(
                        source: source,
                        destination: destination,
                        underlyingError: error,
                    )
                }
            }
        }
    }

    private static func moveFile(
        from source: URL,
        to destination: URL,
        collisionPolicy: DownloadCollisionPolicy,
    ) throws {
        switch collisionPolicy {
        case .failIfExists:
            try FileManager.default.moveItem(at: source, to: destination)
        case .replaceExisting:
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: source)
            } else {
                try FileManager.default.moveItem(at: source, to: destination)
            }
        }
    }

    private static func isSameFileLocation(_ source: URL, _ destination: URL) -> Bool {
        guard source.isFileURL, destination.isFileURL else {
            return false
        }

        return source.standardizedFileURL == destination.standardizedFileURL
    }

    private static func isMissingFileError(_ error: any Error) -> Bool {
        var currentError: NSError? = error as NSError
        while let value = currentError {
            if value.domain == NSCocoaErrorDomain, value.code == NSFileNoSuchFileError {
                return true
            }
            if value.domain == NSPOSIXErrorDomain, value.code == 2 || value.code == 20 {
                // POSIX ENOENT and ENOTDIR both establish that this path is absent.
                return true
            }
            currentError = value.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }

    deinit {
        discard()
    }
}

/// A successfully validated response body held in library-owned or caller-selected storage.
///
/// Temporary files are removed automatically while the URL remains unexposed. Reading `url`,
/// moving the file, or finalizing it to a caller-selected destination transfers cleanup responsibility
/// away from the library.
public final class DownloadedFile: Sendable {
    package let ownership: DownloadedFileStorage

    package init(ownership: DownloadedFileStorage) {
        self.ownership = ownership
    }

    /// The file's current location. Reading this property transfers cleanup responsibility to you.
    public var url: URL {
        ownership.transferURLToCaller()
    }

    /// Moves the file to a new location and updates `url` after the move succeeds.
    ///
    /// A failed move leaves the current location and automatic cleanup responsibility unchanged.
    ///
    /// - Parameters:
    ///   - destination: The file URL that should receive the download.
    ///   - collisionPolicy: The action to take when a file already exists at the destination.
    public func move(
        to destination: URL,
        collisionPolicy: DownloadCollisionPolicy = .failIfExists,
    ) throws {
        try ownership.move(to: destination, collisionPolicy: collisionPolicy)
    }

    /// Removes the file at its current location.
    ///
    /// Repeated calls succeed when the file has already been removed. Once absence is established,
    /// the library will not remove a later file recreated at the same path.
    public func remove() throws {
        try ownership.remove()
    }
}
