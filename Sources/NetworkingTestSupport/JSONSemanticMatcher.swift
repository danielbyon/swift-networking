//
//  JSONSemanticMatcher.swift
//  swift-networking
//
//  SPDX-License-Identifier: MIT
//

import CoreFoundation
import Foundation

/// Builds a Sendable body predicate after validating its expected JSON bytes.
enum JSONSemanticMatcher {
    static func predicate(expected: Data) throws -> @Sendable (Data) -> Bool {
        let expectedValue = try JSONSemanticValue.decode(expected)
        return { actual in
            guard let actualValue = try? JSONSemanticValue.decode(actual) else {
                return false
            }

            return actualValue == expectedValue
        }
    }
}

private enum JSONSemanticValue: Sendable, Equatable {
    case null
    case boolean(Bool)
    case number(JSONNumber)
    case string(String)
    case array([JSONSemanticValue])
    case object([String: JSONSemanticValue])

    static func decode(_ data: Data) throws -> Self {
        do {
            let (rewrittenData, numberTokens) = try JSONNumberTokenRewriter(data: data).rewrite()
            let value = try JSONSerialization.jsonObject(with: rewrittenData, options: [.fragmentsAllowed])
            guard let result = makeValue(value, numberTokens: numberTokens) else {
                throw RequestMatcherError.invalidJSON
            }

            return result
        } catch {
            throw RequestMatcherError.invalidJSON
        }
    }

    private static func makeValue(_ rawValue: Any, numberTokens: [Int: JSONNumber]) -> Self? {
        if rawValue is NSNull {
            return .null
        }
        if let number = rawValue as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .boolean(number.boolValue)
            }
            // Foundation sees only these generated integer markers, never source JSON numbers.
            let tokenIndex = number.intValue
            guard tokenIndex >= 0,
                  NSNumber(value: tokenIndex).compare(number) == .orderedSame,
                  let exactNumber = numberTokens[tokenIndex]
            else {
                return nil
            }

            return .number(exactNumber)
        }
        if let string = rawValue as? String {
            return .string(string)
        }
        if let arrayValues = rawValue as? [Any] {
            let decoded = arrayValues.compactMap { makeValue($0, numberTokens: numberTokens) }
            return decoded.count == arrayValues.count ? .array(decoded) : nil
        }
        if let objectValues = rawValue as? [String: Any] {
            var decoded: [String: Self] = [:]
            for (key, childValue) in objectValues {
                guard let decodedValue = makeValue(childValue, numberTokens: numberTokens) else {
                    return nil
                }

                decoded[key] = decodedValue
            }
            return .object(decoded)
        }
        return nil
    }
}

/// Replaces source number tokens before Foundation decodes the JSON structure.
///
/// The scanner is shared by semantic equality and canonical snapshot rendering so both agree on
/// which byte ranges are numbers and which number spellings are valid.
struct JSONNumberTokenRewriter {
    private let bytes: [UInt8]

    init(data: Data) {
        bytes = Array(data)
    }

    func rewrite() throws -> (data: Data, numberTokens: [Int: JSONNumber]) {
        var rewritten: [UInt8] = []
        var numberTokens: [Int: JSONNumber] = [:]
        var index = 0

        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x22 {
                let end = Self.stringEnd(in: bytes, startingAt: index)
                rewritten.append(contentsOf: bytes[index ..< end])
                index = end
            } else if byte == 0x2d || Self.isDigit(byte) {
                let end = try Self.numberEnd(in: bytes, startingAt: index)
                let token = String(decoding: bytes[index ..< end], as: UTF8.self)
                guard let number = JSONNumber(token) else {
                    throw RequestMatcherError.invalidJSON
                }

                let tokenIndex = numberTokens.count
                numberTokens[tokenIndex] = number
                rewritten.append(contentsOf: String(tokenIndex).utf8)
                index = end
            } else {
                rewritten.append(byte)
                index += 1
            }
        }

        return (Data(rewritten), numberTokens)
    }

    private static func stringEnd(in bytes: [UInt8], startingAt start: Int) -> Int {
        var index = start + 1
        var escaped = false
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            if escaped {
                escaped = false
            } else if byte == 0x5c {
                escaped = true
            } else if byte == 0x22 {
                return index
            }
        }

        return bytes.count
    }

    private static func numberEnd(in bytes: [UInt8], startingAt start: Int) throws -> Int {
        var index = start
        if bytes[index] == 0x2d {
            index += 1
        }
        index = try integerEnd(in: bytes, startingAt: index)
        if index < bytes.count, bytes[index] == 0x2e {
            index = try fractionEnd(in: bytes, startingAt: index)
        }
        if index < bytes.count, isExponentMarker(bytes[index]) {
            index = try exponentEnd(in: bytes, startingAt: index)
        }
        guard hasValidNumberTerminator(in: bytes, at: index) else {
            throw RequestMatcherError.invalidJSON
        }

        return index
    }

    private static func integerEnd(in bytes: [UInt8], startingAt start: Int) throws -> Int {
        guard start < bytes.count else {
            throw RequestMatcherError.invalidJSON
        }

        var index = start
        switch bytes[index] {
        case 0x30:
            index += 1
            guard index == bytes.count || !isDigit(bytes[index]) else {
                throw RequestMatcherError.invalidJSON
            }

        case 0x31 ... 0x39:
            index += 1
            while index < bytes.count, isDigit(bytes[index]) {
                index += 1
            }
        default:
            throw RequestMatcherError.invalidJSON
        }

        return index
    }

    private static func fractionEnd(in bytes: [UInt8], startingAt start: Int) throws -> Int {
        var index = start + 1
        guard index < bytes.count, isDigit(bytes[index]) else {
            throw RequestMatcherError.invalidJSON
        }

        while index < bytes.count, isDigit(bytes[index]) {
            index += 1
        }

        return index
    }

    private static func exponentEnd(in bytes: [UInt8], startingAt start: Int) throws -> Int {
        var index = start + 1
        if index < bytes.count, isExponentSign(bytes[index]) {
            index += 1
        }
        guard index < bytes.count, isDigit(bytes[index]) else {
            throw RequestMatcherError.invalidJSON
        }

        while index < bytes.count, isDigit(bytes[index]) {
            index += 1
        }

        return index
    }

    private static func isExponentMarker(_ byte: UInt8) -> Bool {
        byte == 0x65 || byte == 0x45
    }

    private static func isExponentSign(_ byte: UInt8) -> Bool {
        byte == 0x2b || byte == 0x2d
    }

    private static func hasValidNumberTerminator(in bytes: [UInt8], at index: Int) -> Bool {
        guard index < bytes.count else {
            return true
        }

        switch bytes[index] {
        case 0x20,
             0x09,
             0x0a,
             0x0d,
             0x2c,
             0x5d,
             0x7d:
            return true
        default:
            return false
        }
    }

    private static func isDigit(_ byte: UInt8) -> Bool {
        (0x30 ... 0x39).contains(byte)
    }
}

/// A canonical decimal value represented as sign, significant digits, and an arbitrary-size exponent.
struct JSONNumber: Sendable, Equatable {
    let isNegative: Bool
    let digits: String
    let exponent: JSONDecimalInteger

    init?(_ source: String) {
        var value = source[...]
        let hasNegativeSign = value.first == "-"
        if hasNegativeSign {
            value = value.dropFirst()
        }

        let significand: Substring
        var normalizedExponent = JSONDecimalInteger.zero
        if let exponentMarker = value.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            significand = value[..<exponentMarker]
            let exponentSource = value[value.index(after: exponentMarker)...]
            guard let parsedExponent = JSONDecimalInteger(String(exponentSource)) else {
                return nil
            }

            normalizedExponent = parsedExponent
        } else {
            significand = value
        }

        let decimalParts = significand.split(separator: ".", omittingEmptySubsequences: false)
        guard decimalParts.count <= 2,
              let integerPart = decimalParts.first,
              Self.containsOnlyDigits(integerPart),
              decimalParts.count == 1 || Self.containsOnlyDigits(decimalParts[1])
        else {
            return nil
        }

        let fraction = decimalParts.count == 2 ? decimalParts[1] : ""
        let allDigits = String(integerPart) + fraction
        let significantDigits = allDigits.drop(while: { $0 == "0" })
        guard !significantDigits.isEmpty else {
            isNegative = false
            digits = "0"
            exponent = .zero
            return
        }

        let trailingZeroCount = allDigits.reversed().prefix(while: { $0 == "0" }).count
        isNegative = hasNegativeSign
        digits = String(significantDigits.dropLast(trailingZeroCount))
        exponent = normalizedExponent.adding(trailingZeroCount - fraction.utf8.count)
    }

    private static func containsOnlyDigits(_ value: Substring) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { (0x30 ... 0x39).contains($0) }
    }
}

/// A signed base-10 integer used to normalize exponents without a machine-width limit.
struct JSONDecimalInteger: Sendable, Equatable {
    let isNegative: Bool
    let digits: String

    static let zero = Self(isNegative: false, digits: "0")

    init?(_ source: String) {
        var value = source[...]
        let hasNegativeSign = value.first == "-"
        if hasNegativeSign || value.first == "+" {
            value = value.dropFirst()
        }
        guard !value.isEmpty,
              value.utf8.allSatisfy({ (0x30 ... 0x39).contains($0) })
        else {
            return nil
        }

        let normalizedDigits = String(value.drop(while: { $0 == "0" }))
        digits = normalizedDigits.isEmpty ? "0" : normalizedDigits
        isNegative = digits == "0" ? false : hasNegativeSign
    }

    private init(isNegative: Bool, digits: String) {
        self.digits = digits
        self.isNegative = digits == "0" ? false : isNegative
    }

    func adding(_ adjustment: Int) -> Self {
        guard adjustment != 0 else {
            return self
        }

        let adjustmentIsNegative = adjustment < 0
        let adjustmentDigits = String(adjustment.magnitude)
        if digits == "0" {
            return Self(isNegative: adjustmentIsNegative, digits: adjustmentDigits)
        }
        if isNegative == adjustmentIsNegative {
            return Self(
                isNegative: isNegative,
                digits: Self.addMagnitudes(digits, adjustmentDigits),
            )
        }

        let magnitudeOrder = Self.compareMagnitudes(digits, adjustmentDigits)
        if magnitudeOrder == 0 {
            return .zero
        }
        if magnitudeOrder > 0 {
            return Self(isNegative: isNegative, digits: Self.subtractMagnitudes(digits, adjustmentDigits))
        }

        return Self(
            isNegative: adjustmentIsNegative,
            digits: Self.subtractMagnitudes(adjustmentDigits, digits),
        )
    }

    private static func addMagnitudes(_ left: String, _ right: String) -> String {
        let leftDigits = Array(left.utf8)
        let rightDigits = Array(right.utf8)
        let count = max(leftDigits.count, rightDigits.count)
        var reversedResult: [UInt8] = []
        var carry = 0

        for offset in 0 ..< count {
            let leftDigit = offset < leftDigits.count ? Int(leftDigits[leftDigits.count - offset - 1] - 0x30) : 0
            let rightDigit = offset < rightDigits.count ? Int(rightDigits[rightDigits.count - offset - 1] - 0x30) : 0
            let sum = leftDigit + rightDigit + carry
            reversedResult.append(UInt8(sum % 10) + 0x30)
            carry = sum / 10
        }
        if carry > 0 {
            reversedResult.append(UInt8(carry) + 0x30)
        }

        return String(decoding: reversedResult.reversed(), as: UTF8.self)
    }

    private static func subtractMagnitudes(_ larger: String, _ smaller: String) -> String {
        let largerDigits = Array(larger.utf8)
        let smallerDigits = Array(smaller.utf8)
        var reversedResult: [UInt8] = []
        var borrow = 0

        for offset in 0 ..< largerDigits.count {
            let largerDigit = Int(largerDigits[largerDigits.count - offset - 1] - 0x30)
            let smallerDigit = offset < smallerDigits.count
                ? Int(smallerDigits[smallerDigits.count - offset - 1] - 0x30)
                : 0
            var difference = largerDigit - smallerDigit - borrow
            if difference < 0 {
                difference += 10
                borrow = 1
            } else {
                borrow = 0
            }
            reversedResult.append(UInt8(difference) + 0x30)
        }
        while reversedResult.last == 0x30 {
            reversedResult.removeLast()
        }

        return String(decoding: reversedResult.reversed(), as: UTF8.self)
    }

    private static func compareMagnitudes(_ left: String, _ right: String) -> Int {
        if left.count != right.count {
            return left.count < right.count ? -1 : 1
        }
        for (leftDigit, rightDigit) in zip(left.utf8, right.utf8) where leftDigit != rightDigit {
            return leftDigit < rightDigit ? -1 : 1
        }

        return 0
    }
}

extension JSONNumberTokenRewriter {
    /// Replaces every source number with a unique quoted placeholder.
    ///
    /// Canonical snapshot rendering uses this mode so Foundation can supply layout and
    /// deterministic object-key ordering while each number keeps the exact spelling from the
    /// source document, including arbitrary-precision decimals and arbitrary-size exponents.
    ///
    /// - Parameter prefix: A caller-unique prefix for the generated placeholders. The prefix must
    ///   contain only characters that need no escaping inside a JSON string literal.
    /// - Returns: The rewritten bytes and each replaced number's original source spelling, keyed by
    ///   the index used in its placeholder.
    func rewriteNumbersAsQuotedPlaceholders(
        prefix: String,
    ) throws -> (data: Data, numberSources: [String]) {
        var rewritten: [UInt8] = []
        var numberSources: [String] = []
        var index = 0

        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x22 {
                let end = Self.stringEnd(in: bytes, startingAt: index)
                rewritten.append(contentsOf: bytes[index ..< end])
                index = end
            } else if byte == 0x2d || Self.isDigit(byte) {
                let end = try Self.numberEnd(in: bytes, startingAt: index)
                let placeholder = "\"" + prefix + String(numberSources.count) + "\""
                rewritten.append(contentsOf: Array(placeholder.utf8))
                numberSources.append(String(decoding: bytes[index ..< end], as: UTF8.self))
                index = end
            } else {
                rewritten.append(byte)
                index += 1
            }
        }

        return (Data(rewritten), numberSources)
    }
}
