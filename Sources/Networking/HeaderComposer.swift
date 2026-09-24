//
//  HeaderComposer.swift
//  swift-networking
//
//  SPDX-License-Identifier: MIT
//

import HTTPTypes

package enum HeaderComposer {
    /// Combines the request's header layers from lowest to highest precedence.
    ///
    /// A layer replaces all lower-precedence values for every field name it contains. Repeated
    /// values in the winning layer retain their HTTPTypes order.
    package static func compose(
        libraryInferred: HTTPFields,
        clientDefaults: HTTPFields,
        endpoint: HTTPFields,
        request: HTTPFields,
    ) -> HTTPFields {
        var result = HTTPFields()
        for layer in [libraryInferred, clientDefaults, endpoint, request] {
            var appliedNames = Set<HTTPField.Name>()
            for field in layer where appliedNames.insert(field.name).inserted {
                result[fields: field.name] = layer[fields: field.name]
            }
        }
        return result
    }
}
