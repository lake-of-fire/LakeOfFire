import Foundation

public enum ReaderDateFormatter {
    public static let defaultAbsoluteFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .none
        return formatter
    }()

    public static func relativeString(
        from date: Date,
        referenceDate: Date = Date(),
        calendar: Calendar = Calendar.current
    ) -> String? {
        let isPast = date <= referenceDate
        let earlierDate = isPast ? date : referenceDate
        let laterDate = isPast ? referenceDate : date

        let components = calendar.dateComponents([
            .year,
            .month,
            .day,
            .hour,
            .minute,
            .second
        ], from: earlierDate, to: laterDate)

        var quantity: Int?
        var unit: String = ""

        if let year = components.year, year > 0 {
            quantity = year
            unit = year == 1 ? "year" : "years"
        } else if let month = components.month, month > 0 {
            quantity = month
            unit = month == 1 ? "month" : "months"
        } else if let day = components.day, day > 0 {
            quantity = day
            unit = day == 1 ? "day" : "days"
        } else if let hour = components.hour, hour > 0 {
            quantity = hour
            unit = hour == 1 ? "hour" : "hours"
        } else if let minute = components.minute, minute > 0 {
            quantity = minute
            unit = minute == 1 ? "minute" : "minutes"
        } else if let second = components.second, second > 0 {
            quantity = second
            unit = second == 1 ? "second" : "seconds"
        }

        guard let quantity else { return nil }
        let phrase = "\(quantity) \(unit)"
        return isPast ? "\(phrase) ago" : "in \(phrase)"
    }

    public static func relativeOrAbsoluteString(
        from date: Date,
        referenceDate: Date = Date(),
        fallbackFormatter: DateFormatter = ReaderDateFormatter.defaultAbsoluteFormatter,
        calendar: Calendar = Calendar.current
    ) -> String {
        if let relative = relativeString(from: date, referenceDate: referenceDate, calendar: calendar) {
            return relative
        }
        return fallbackFormatter.string(from: date)
    }

    public static func absoluteString(
        from date: Date,
        dateFormatter: DateFormatter = ReaderDateFormatter.defaultAbsoluteFormatter
    ) -> String {
        return dateFormatter.string(from: date)
    }

    public static func makeAbsoluteFormatter(
        dateStyle: DateFormatter.Style = .long,
        timeStyle: DateFormatter.Style = .none
    ) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateStyle = dateStyle
        formatter.timeStyle = timeStyle
        return formatter
    }
}
