//
//  DownloadDestination.swift
//  swift-networking
//
//  SPDX-License-Identifier: MIT
//

import Foundation
import HTTPTypes

/// Selects where an accepted download is stored after response validation succeeds.
public enum DownloadDestination: Sendable {
    /// Keeps the accepted download in library-owned temporary storage.
    case temporary

    /// Moves the accepted download to a fixed file URL.
    ///
    /// - Parameters:
    ///   - url: The destination file URL.
    ///   - collisionPolicy: The action to take when the destination already exists.
    case file(URL, collisionPolicy: DownloadCollisionPolicy = .failIfExists)

    /// Resolves a destination from the accepted HTTP response and immutable request context.
    ///
    /// The resolver runs once, after authentication recovery, retries, and response validation have
    /// completed. It does not receive the temporary download URL.
    ///
    /// - Parameters:
    ///   - collisionPolicy: The action to take when the resolved destination already exists.
    ///   - resolver: A synchronous throwing closure that returns the destination file URL.
    case resolved(
        collisionPolicy: DownloadCollisionPolicy = .failIfExists,
        resolver: @Sendable (HTTPResponse, RequestContext) throws -> URL,
    )
}

/// Selects how a download transfer handles an existing destination file.
public enum DownloadCollisionPolicy: Sendable {
    /// Fails without replacing an existing destination.
    case failIfExists

    /// Replaces an existing destination using the filesystem replacement operation when available.
    ///
    /// Replacement is best-effort atomic on supported filesystems. Filesystem and volume boundaries
    /// can limit the guarantees available to the underlying platform.
    case replaceExisting
}

/// Describes a failure while finalizing or managing a downloaded file.
///
/// The underlying error is the filesystem error that prevented the requested operation. Resolver
/// errors are propagated directly and are not wrapped in this type.
public enum DownloadFileError: Error, Sendable {
    /// The accepted response file could not be moved to its selected destination.
    case finalizationFailed(source: URL, destination: URL, underlyingError: any Error)

    /// A caller-requested move could not be completed.
    case moveFailed(source: URL, destination: URL, underlyingError: any Error)

    /// The current file could not be removed.
    case removeFailed(url: URL, underlyingError: any Error)
}
