//
//  DownloadedFile.swift
//  swift-networking
//
//  SPDX-License-Identifier: MIT
//

import Foundation
import Synchronization

/// Holds a completed download in library-owned temporary storage until its owner releases it.
///
/// The URL is package-internal so authentication and validation callbacks can inspect the file
/// without receiving an ownership token. The token removes the file when it is discarded or when
/// its final owner is released.
package final class LibraryOwnedTemporaryFile: Sendable {
    private enum State: Sendable {
        case owned
        case discarding
        case discarded
    }

    package let url: URL
    private let state = Mutex<State>(.owned)

    private init(url: URL) {
        self.url = url
    }

    package static func adopt(_ foundationURL: URL) throws -> Self {
        let ownedURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "swift-networking-download-\(UUID().uuidString)",
        )
        try FileManager.default.moveItem(at: foundationURL, to: ownedURL)
        return Self(url: ownedURL)
    }

    /// Removes the owned file once and permits later cleanup retries if removal fails.
    package func discard() {
        let shouldRemove = state.withLock { currentState -> Bool in
            guard case .owned = currentState else {
                return false
            }

            currentState = .discarding
            return true
        }
        guard shouldRemove else {
            return
        }

        do {
            try FileManager.default.removeItem(at: url)
            state.withLock { $0 = .discarded }
        } catch {
            if FileManager.default.fileExists(atPath: url.path) {
                state.withLock { currentState in
                    if case .discarding = currentState {
                        currentState = .owned
                    }
                }
            } else {
                state.withLock { $0 = .discarded }
            }
        }
    }

    deinit {
        discard()
    }
}

/// A successfully validated response body held in library-owned temporary storage.
///
/// The file remains owned while this object is alive. Networking removes it automatically when
/// the object is deallocated. This type does not expose a durable URL or file-transfer operations.
public final class DownloadedFile: Sendable {
    package let ownership: LibraryOwnedTemporaryFile

    package init(ownership: LibraryOwnedTemporaryFile) {
        self.ownership = ownership
    }
}
