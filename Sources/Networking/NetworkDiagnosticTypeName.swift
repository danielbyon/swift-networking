//
//  NetworkDiagnosticTypeName.swift
//  swift-networking
//
//  SPDX-License-Identifier: MIT
//

/// Produces deterministic Swift type identifiers for public diagnostic output.
enum NetworkDiagnosticTypeName {
    /// Removes runtime context and generic arguments, optionally preserving stable namespaces.
    static func stableName(for type: Any.Type, includingNamespace: Bool = false) -> String {
        let reflectedTypeName = String(reflecting: type)
        let contextFreeTypeName = removingRuntimeTypeContextSegments(from: reflectedTypeName)
        let outerNominalPath = contextFreeTypeName.prefix { $0 != "<" && $0 != "[" && $0 != "(" }
        let components = outerNominalPath.split(separator: ".", omittingEmptySubsequences: true)
        let selectedComponents = includingNamespace ? Array(components) : Array(components.suffix(1))
        let identifiers = selectedComponents.compactMap { component -> String? in
            let identifierBytes = component.utf8.prefix { byte in
                (byte >= 65 && byte <= 90)
                    || (byte >= 97 && byte <= 122)
                    || (byte >= 48 && byte <= 57)
                    || byte == 95
            }
            let identifier = String(decoding: identifierBytes, as: UTF8.self)
            guard let firstByte = identifier.utf8.first,
                  (firstByte >= 65 && firstByte <= 90)
                  || (firstByte >= 97 && firstByte <= 122)
                  || firstByte == 95,
                  identifier.lowercased() != "unknown"
            else {
                return nil
            }

            return identifier
        }
        guard identifiers.count == selectedComponents.count, identifiers.isEmpty == false else {
            return "Error"
        }

        return identifiers.joined(separator: ".")
    }

    /// Removes parenthesized compiler context or address segments from a reflected type name.
    private static func removingRuntimeTypeContextSegments(from value: String) -> String {
        var result = String()
        result.reserveCapacity(value.utf8.count)
        var index = value.startIndex

        while index < value.endIndex {
            if value[index] == "(" {
                var contextIndex = index
                var nestingDepth = 0
                var contextEnd: String.Index?

                while contextIndex < value.endIndex {
                    switch value[contextIndex] {
                    case "(":
                        nestingDepth += 1
                    case ")":
                        nestingDepth -= 1
                        if nestingDepth == 0 {
                            contextEnd = contextIndex
                        }
                    default:
                        break
                    }

                    if contextEnd != nil {
                        break
                    }
                    value.formIndex(after: &contextIndex)
                }

                guard let contextEnd else {
                    return ""
                }

                let contextEndIndex = value.index(after: contextEnd)
                let contextSegment = value[index ..< contextEndIndex]
                if isRuntimeTypeContextSegment(contextSegment) {
                    index = contextEndIndex
                    continue
                }
            }

            result.append(value[index])
            value.formIndex(after: &index)
        }

        return result
    }

    private static func isRuntimeTypeContextSegment(_ value: Substring) -> Bool {
        let lowercasedValue = value.lowercased()
        return value.contains("$")
            || lowercasedValue.contains("0x")
            || lowercasedValue.contains("context at")
            || lowercasedValue.contains("function at")
    }
}
