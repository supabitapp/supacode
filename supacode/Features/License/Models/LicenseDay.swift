import Foundation

nonisolated struct LicenseDay: Codable, Comparable, Hashable, RawRepresentable, Sendable {
  let rawValue: String

  init?(_ rawValue: String) {
    let bytes = Array(rawValue.utf8)
    guard
      bytes.count == 10,
      bytes[4] == 45,
      bytes[7] == 45,
      bytes.enumerated().allSatisfy({ index, byte in
        index == 4 || index == 7 || (48...57).contains(byte)
      })
    else { return nil }

    let year = Int(rawValue.prefix(4)) ?? 0
    let month = Int(rawValue.dropFirst(5).prefix(2)) ?? 0
    let day = Int(rawValue.suffix(2)) ?? 0
    let leapYear = year.isMultiple(of: 4) && (!year.isMultiple(of: 100) || year.isMultiple(of: 400))
    let daysInMonth = [31, leapYear ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    guard year > 0, (1...12).contains(month), (1...daysInMonth[month - 1]).contains(day)
    else { return nil }

    self.rawValue = rawValue
  }

  init?(rawValue: String) {
    self.init(rawValue)
  }

  static func < (lhs: Self, rhs: Self) -> Bool {
    lhs.rawValue < rhs.rawValue
  }

  static func today(at date: Date = .now) -> Self {
    guard let utc = TimeZone(secondsFromGMT: 0) else {
      preconditionFailure("UTC time zone unavailable")
    }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = utc
    let components = calendar.dateComponents([.year, .month, .day], from: date)
    guard
      let year = components.year,
      let month = components.month,
      let day = components.day,
      let value = Self(String(format: "%04d-%02d-%02d", year, month, day))
    else {
      preconditionFailure("Invalid UTC calendar day")
    }
    return value
  }

  /// The day as a long localized date, read in UTC so it never shifts by a day.
  func formatted(locale: Locale = .autoupdatingCurrent) -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .gmt
    let parts = rawValue.split(separator: "-").compactMap { Int($0) }
    guard parts.count == 3,
      let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    else { return rawValue }
    var displayCalendar = locale.calendar
    displayCalendar.timeZone = .gmt
    return date.formatted(
      Date.FormatStyle(date: .long, time: .omitted, locale: locale, calendar: displayCalendar, timeZone: .gmt))
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    let rawValue = try container.decode(String.self)
    guard let day = Self(rawValue) else {
      throw DecodingError.dataCorruptedError(
        in: container,
        debugDescription: "Invalid license day"
      )
    }
    self = day
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}
