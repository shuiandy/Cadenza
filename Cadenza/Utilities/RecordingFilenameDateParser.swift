import Foundation

enum RecordingFilenameDateParser {
    private static let supportedPatterns = [
        #"(\d{4})-(\d{2})-(\d{2})_(\d{2})-(\d{2})-(\d{2})"#,
        #"(\d{4})(\d{2})(\d{2})[_-](\d{2})(\d{2})(\d{2})"#
    ]

    static func parse(_ filename: String, calendar: Calendar = .current) -> Date? {
        for pattern in supportedPatterns {
            guard let match = filename.range(of: pattern, options: .regularExpression) else {
                continue
            }
            let matched = String(filename[match])
            let digits = matched.filter(\.isNumber)
            guard digits.count == 14,
                  let year = Int(digits.prefix(4)),
                  let month = Int(digits.dropFirst(4).prefix(2)),
                  let day = Int(digits.dropFirst(6).prefix(2)),
                  let hour = Int(digits.dropFirst(8).prefix(2)),
                  let minute = Int(digits.dropFirst(10).prefix(2)),
                  let second = Int(digits.dropFirst(12).prefix(2)) else {
                continue
            }

            let components = DateComponents(
                calendar: calendar,
                year: year,
                month: month,
                day: day,
                hour: hour,
                minute: minute,
                second: second
            )
            if let date = components.date {
                return date
            }
        }
        return nil
    }
}
