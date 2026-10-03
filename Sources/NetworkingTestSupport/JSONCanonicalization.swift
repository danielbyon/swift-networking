//
//  JSONCanonicalization.swift
//  swift-networking
//
//  SPDX-License-Identifier: MIT
//

import Foundation

/// Renders validated JSON bytes as deterministic, pretty-printed JSON.
///
/// Foundation supplies the layout and the deterministic object-key ordering, but it cannot
/// represent every JSON number without loss. This type therefore temporarily replaces each source
/// number with a quoted placeholder, lets Foundation re-render the document, and restores the
/// original number spellings. Array order is preserved because Foundation keeps arrays ordered.
enum JSONCanonicalization {
    /// Returns pretty-printed JSON with sorted object keys and each source number spelling intact.
    ///
    /// - Parameter data: Validated JSON bytes, typically obtained from a `JSONFixture`.
    /// - Throws: `JSONFixture.LoadingError.canonicalizationFailed` when the bytes cannot be
    ///   rendered. Content that already passed semantic JSON validation does not reach this state.
    static func canonicalData(from data: Data) throws -> Data {
        let prefix = "networking-number-" + UUID().uuidString + "-"
        do {
            let (rewritten, numberSources) = try JSONNumberTokenRewriter(data: data)
                .rewriteNumbersAsQuotedPlaceholders(prefix: prefix)
            let decoded = try JSONSerialization.jsonObject(with: rewritten, options: [.fragmentsAllowed])
            let encoded = try JSONSerialization.data(
                withJSONObject: decoded,
                options: [.fragmentsAllowed, .prettyPrinted, .sortedKeys, .withoutEscapingSlashes],
            )

            return try restoringNumbers(numberSources, prefix: prefix, in: encoded)
        } catch {
            throw JSONFixture.LoadingError.canonicalizationFailed(reason: String(describing: error))
        }
    }

    /// Replaces every quoted placeholder with the number spelling it stood in for.
    private static func restoringNumbers(
        _ numberSources: [String],
        prefix: String,
        in encoded: Data,
    ) throws -> Data {
        var result = encoded
        for (index, source) in numberSources.enumerated() {
            let placeholder = Data(("\"" + prefix + String(index) + "\"").utf8)
            guard let range = result.range(of: placeholder) else {
                throw JSONFixture.LoadingError.canonicalizationFailed(reason: "missing number placeholder")
            }

            result.replaceSubrange(range, with: Data(source.utf8))
        }

        return result
    }
}
