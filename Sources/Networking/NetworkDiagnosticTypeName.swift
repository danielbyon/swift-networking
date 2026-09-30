//
//  NetworkDiagnosticTypeName.swift
//  swift-networking
//
//  SPDX-License-Identifier: MIT
//

/// Produces deterministic Swift type identifiers for public diagnostic output.
enum NetworkDiagnosticTypeName {
    /// Removes runtime context and generic arguments while retaining nested nominal path components.
    static func stableName(for type: Any.Type, includingNamespace: Bool = false) -> String {
        let reflectedTypeName = String(reflecting: type)
        let contextFreeTypeName = removingRuntimeTypeContextSegments(from: reflectedTypeName)
        let nominalPath = removingGenericArgumentLists(from: contextFreeTypeName)
        let components = nominalPath.prefix { $0 != "[" && $0 != "(" }
            .split(separator: ".", omittingEmptySubsequences: true)
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

    /// Retains normalized generic arguments for request-context key identity.
    ///
    /// Error summaries use `stableName(for:includingNamespace:)` to keep their labels compact. Context keys
    /// use their generic arguments because distinct specializations may opt in different diagnostic values.
    static func contextKeyName(for type: Any.Type) -> String {
        let reflectedTypeName = String(reflecting: type)
        let contextFreeTypeName = removingRuntimeTypeContextSegments(from: reflectedTypeName)
        let normalizedName = normalizingContextKeyTypeName(contextFreeTypeName)
        return normalizedName.isEmpty ? "Error" : normalizedName
    }

    /// Preserves reflected generic structure and encodes unsupported Unicode scalars deterministically.
    private static func normalizingContextKeyTypeName(_ value: String) -> String {
        var result = String()
        result.reserveCapacity(value.utf8.count)

        for character in value {
            guard character.isWhitespace == false else {
                continue
            }

            let isIdentifierCharacter = character.isLetter || character.isNumber || character == "_"
            let isTypeSyntaxCharacter = "<>,.?&()[]:-!".contains(character)
            if isIdentifierCharacter == false, isTypeSyntaxCharacter == false {
                for scalar in character.unicodeScalars {
                    result.append("~u{\(String(scalar.value, radix: 16, uppercase: true))}")
                }
                continue
            }

            if character == ".",
               result.isEmpty || result.last == "." || result.last == "<" || result.last == "," {
                continue
            }
            if character == ">", result.last == "." {
                result.removeLast()
            }
            result.append(character)
        }

        while result.last == "." {
            result.removeLast()
        }
        return result
    }

    /// Removes balanced generic argument lists while retaining nominal components that follow them.
    private static func removingGenericArgumentLists(from value: String) -> String {
        var result = String()
        result.reserveCapacity(value.utf8.count)
        var index = value.startIndex

        while index < value.endIndex {
            guard value[index] == "<" else {
                result.append(value[index])
                value.formIndex(after: &index)
                continue
            }
            guard let closingIndex = genericArgumentListEnd(in: value, startingAt: index) else {
                // Preserve the known nominal prefix and discard only the malformed suffix.
                return result
            }

            index = value.index(after: closingIndex)
        }

        return result
    }

    /// Finds a balanced generic-list terminator without counting the `>` in function arrows.
    private static func genericArgumentListEnd(in value: String, startingAt start: String.Index) -> String.Index? {
        var genericDepth = 0
        var index = start

        while index < value.endIndex {
            switch value[index] {
            case "<":
                genericDepth += 1
            case ">":
                let isFunctionArrow = index > start && value[value.index(before: index)] == "-"
                if isFunctionArrow == false {
                    genericDepth -= 1
                    if genericDepth == 0 {
                        return index
                    }
                }
            default:
                break
            }

            value.formIndex(after: &index)
        }

        return nil
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
        return lowercasedValue.hasPrefix("(unknown context at")
            || lowercasedValue.hasPrefix("(function at")
            || lowercasedValue.hasPrefix("(context at")
    }
}
