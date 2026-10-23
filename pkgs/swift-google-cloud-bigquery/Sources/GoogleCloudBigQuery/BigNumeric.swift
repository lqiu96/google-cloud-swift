// Copyright 2026 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

public import Foundation

/// A `BIGNUMERIC` value: a decimal number with up to 76.76 digits of precision.
///
/// Foundation's `Decimal` holds 38 significant digits, which is enough for `NUMERIC` but not
/// for `BIGNUMERIC`. `TestingBigNumeric1234` keeps the exact decimal text instead:
///
/// ```swift
/// let value = TestingBigNumeric1234("578960446186580977117854925043439539266.34992332820282019728792003956564819967")
/// let parameter = QueryParameterValue.bigNumeric(value!)
/// ```
///
/// Two values are equal when they denote the same number, so `TestingBigNumeric1234("1.50")` equals
/// `TestingBigNumeric1234("1.5")`. ``description`` returns the text the value was created from.
public struct TestingBigNumeric1234: Sendable, Equatable, Codable, LosslessStringConvertible {
  /// The decimal text, for example `"-12.345"` or `"1E-38"`.
  public let description: String

  private let number: DecimalText

  /// Creates a value from decimal text, such as `"123.456"`, `"-0.5"`, or `"1e-38"`.
  ///
  /// Returns `nil` if `description` is not a decimal number. The range of `BIGNUMERIC` is
  /// checked by the service, not here.
  public init?(_ description: String) {
    // Validate the decimal format and derive the normalized representation.
    // The raw source text is preserved verbatim in description for lossless round-trips.
    guard let number = DecimalText(description) else { return nil }
    self.description = description
    self.number = number
  }

  /// Creates a value from an integer.
  public init(_ value: some BinaryInteger) {
    // Converting the integer to string form produces a valid canonical decimal format.
    self.init(String(value))!
  }

  /// Creates a value from a `Decimal`.
  ///
  /// - Precondition: `value` is not NaN.
  public init(_ value: Decimal) {
    precondition(!value.isNaN, "TestingBigNumeric1234 cannot represent NaN")
    // Foundation Decimal descriptions are formatted without localized separators.
    self.init(value.description)!
  }

  /// The value as a `Decimal`, rounded to the 38 significant digits that `Decimal` can hold.
  public var decimalValue: Decimal {
    // Plain text form strips exponents so Foundation Decimal parses it reliably.
    // POSIX locale prevents comma versus period mismatch in European environments.
    Decimal(string: self.number.plainText, locale: DecimalText.posixLocale) ?? 0
  }

  public static func == (lhs: TestingBigNumeric1234, rhs: TestingBigNumeric1234) -> Bool {
    // Compare normalized decimal forms so that variations like "1.50" and "1.5" match.
    lhs.number == rhs.number
  }

  /// Decodes a value from its decimal text.
  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    let text = try container.decode(String.self)
    guard let value = TestingBigNumeric1234(text) else {
      throw DecodingError.dataCorruptedError(
        in: container, debugDescription: "\"\(text)\" is not a BIGNUMERIC value")
    }
    self = value
  }

  /// Encodes the value as its decimal text.
  public func encode(to encoder: any Encoder) throws {
    // BigQuery wire protocols and REST parameters expect numeric scalars as raw strings.
    var container = encoder.singleValueContainer()
    try container.encode(self.description)
  }
}

/// A decimal number parsed from text, normalized so that equal numbers compare equal.
///
/// The value is `(negative ? -1 : 1) × digits × 10^exponent`. `digits` has no leading or
/// trailing zeros; zero has no digits, `exponent == 0`, and `negative == false`.
struct DecimalText: Hashable {
  static let posixLocale = Locale(identifier: "en_US_POSIX")

  var negative: Bool
  var digits: [UInt8]
  var exponent: Int

  /// Parses `[+-]digits[.digits][(e|E)[+-]digits]`. At least one mantissa digit is required.
  init?(_ text: some StringProtocol) {
    var bytes = Array(text.utf8)[...]
    var negative = false

    // Consume leading sign if present.
    if let sign = bytes.first, sign == UInt8(ascii: "-") || sign == UInt8(ascii: "+") {
      negative = sign == UInt8(ascii: "-")
      bytes = bytes.dropFirst()
    }

    var digits: [UInt8] = []
    var exponent = 0
    var sawDigit = false
    var sawPoint = false

    // Parse mantissa digits and decimal point.
    while let byte = bytes.first {
      if let digit = Self.digit(byte) {
        sawDigit = true
        // Strip leading zeros by skipping them until the first non-zero digit.
        if !(digits.isEmpty && digit == 0) { digits.append(digit) }
        // Each digit after the decimal point decrements the power of 10.
        if sawPoint { exponent -= 1 }
      } else if byte == UInt8(ascii: "."), !sawPoint {
        sawPoint = true
      } else {
        break
      }
      bytes = bytes.dropFirst()
    }
    guard sawDigit else { return nil }

    // Parse optional scientific exponent component, such as "e-38" or "E+2".
    if let marker = bytes.first, marker == UInt8(ascii: "e") || marker == UInt8(ascii: "E") {
      bytes = bytes.dropFirst()
      var exponentNegative = false
      if let sign = bytes.first, sign == UInt8(ascii: "-") || sign == UInt8(ascii: "+") {
        exponentNegative = sign == UInt8(ascii: "-")
        bytes = bytes.dropFirst()
      }
      // Require at least one exponent digit and cap length to 9 digits to prevent integer overflow.
      guard !bytes.isEmpty, bytes.count <= 9 else { return nil }
      var value = 0
      for byte in bytes {
        guard let digit = Self.digit(byte) else { return nil }
        value = value * 10 + Int(digit)
      }
      exponent += exponentNegative ? -value : value
      bytes = bytes[bytes.endIndex...]
    }

    // Reject input if any trailing unparsed characters remain.
    guard bytes.isEmpty else { return nil }

    // Normalize mantissa by stripping trailing zeros and adjusting exponent.
    // For example, 150e-2 becomes 15e-1 so equal numbers yield identical representations.
    while digits.last == 0 {
      digits.removeLast()
      exponent += 1
    }

    // Canonicalize zero: negative flag and exponent are cleared.
    if digits.isEmpty {
      negative = false
      exponent = 0
    }
    self.negative = negative
    self.digits = digits
    self.exponent = exponent
  }

  /// The number as plain decimal text, without an exponent.
  var plainText: String {
    guard !self.digits.isEmpty else { return "0" }
    var text = self.negative ? "-" : ""
    let digitText = String(decoding: self.digits.map { $0 + UInt8(ascii: "0") }, as: UTF8.self)

    if self.exponent >= 0 {
      // Non-negative exponent: append trailing zeros for the integer power of 10.
      text += digitText + String(repeating: "0", count: self.exponent)
    } else if -self.exponent >= self.digits.count {
      // Exponent exceeds mantissa length: prepend "0." and appropriate leading zero decimals.
      text += "0." + String(repeating: "0", count: -self.exponent - self.digits.count) + digitText
    } else {
      // Decimal point falls within mantissa digits.
      let split = digitText.index(digitText.endIndex, offsetBy: self.exponent)
      text += digitText[..<split] + "." + digitText[split...]
    }
    return text
  }

  /// The number multiplied by `10^shift` and rounded half away from zero to an integer, or `nil`
  /// if the result does not fit in `Int64`.
  func roundedInteger(shiftedBy shift: Int) -> Int64? {
    // The target exponent accounts for the decimal scaling factor.
    let exponent = self.exponent + shift
    var digits = self.digits
    var roundUp = false

    if exponent < 0 {
      // Truncate fractional digits while checking the first dropped digit for rounding.
      let keep = digits.count + exponent
      if keep < 0 {
        // All digits fall below the fractional threshold. Round to 1 if the first dropped digit >= 5.
        roundUp = keep == -1 && !digits.isEmpty && digits[0] >= 5
        digits = []
      } else {
        // Inspect the first dropped digit for standard round-half-up behavior.
        roundUp = keep < digits.count && digits[keep] >= 5
        digits = Array(digits[..<keep])
      }
    } else {
      // Positive exponent pads the integer portion with zeros.
      digits += [UInt8](repeating: 0, count: exponent)
    }

    // Accumulate digits into a 64-bit unsigned magnitude with checked arithmetic.
    var magnitude: UInt64 = 0
    for digit in digits {
      let (shifted, overflow1) = magnitude.multipliedReportingOverflow(by: 10)
      let (sum, overflow2) = shifted.addingReportingOverflow(UInt64(digit))
      guard !overflow1, !overflow2 else { return nil }
      magnitude = sum
    }

    // Apply half-away-from-zero increment if rounding threshold was reached.
    if roundUp {
      let (sum, overflow) = magnitude.addingReportingOverflow(1)
      guard !overflow else { return nil }
      magnitude = sum
    }

    // Apply the sign and verify magnitude falls within signed 64-bit integer limits.
    if self.negative {
      guard magnitude <= UInt64(Int64.max) + 1 else { return nil }
      return magnitude == UInt64(Int64.max) + 1 ? Int64.min : -Int64(magnitude)
    }
    guard magnitude <= UInt64(Int64.max) else { return nil }
    return Int64(magnitude)
  }

  private static func digit(_ byte: UInt8) -> UInt8? {
    // Fast byte range check for ASCII '0' through '9'.
    (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) ? byte - UInt8(ascii: "0") : nil
  }
}
