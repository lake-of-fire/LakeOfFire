import Foundation

public enum ReaderDateFormatter {
    public enum RelativeDurationStyle {
        case long
        case short
    }

    public static let defaultAbsoluteFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .none
        return formatter
    }()

    public static func relativeString(
        from date: Date,
        referenceDate: Date = Date(),
        calendar: Calendar = Calendar.current,
        style: RelativeDurationStyle = .long
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
        var longUnitSingular: String = ""
        var longUnitPlural: String = ""
        var shortUnit: String = ""

        if let year = components.year, year > 0 {
            quantity = year
            longUnitSingular = "year"
            longUnitPlural = "years"
            shortUnit = "y"
        } else if let month = components.month, month > 0 {
            quantity = month
            longUnitSingular = "month"
            longUnitPlural = "months"
            shortUnit = "mo"
        } else if let day = components.day, day > 0 {
            quantity = day
            longUnitSingular = "day"
            longUnitPlural = "days"
            shortUnit = "d"
        } else if let hour = components.hour, hour > 0 {
            quantity = hour
            longUnitSingular = "hour"
            longUnitPlural = "hours"
            shortUnit = "h"
        } else if let minute = components.minute, minute > 0 {
            quantity = minute
            longUnitSingular = "minute"
            longUnitPlural = "minutes"
            shortUnit = "m"
        } else if let second = components.second, second > 0 {
            quantity = second
            longUnitSingular = "second"
            longUnitPlural = "seconds"
            shortUnit = "s"
        }

        guard let quantity else { return nil }
        let phrase: String

        switch style {
        case .long:
            let unit = quantity == 1 ? longUnitSingular : longUnitPlural
            phrase = "\(quantity) \(unit)"
        case .short:
            phrase = "\(quantity)\(shortUnit)"
        }
        return isPast ? "\(phrase) ago" : "in \(phrase)"
    }

    public static func relativeOrAbsoluteString(
        from date: Date,
        referenceDate: Date = Date(),
        fallbackFormatter: DateFormatter = ReaderDateFormatter.defaultAbsoluteFormatter,
        calendar: Calendar = Calendar.current,
        style: RelativeDurationStyle = .long
    ) -> String {
        if let relative = relativeString(
            from: date,
            referenceDate: referenceDate,
            calendar: calendar,
            style: style
        ) {
            return relative
        }
        return fallbackFormatter.string(from: date)
    }

    public static func shortDurationString(from duration: TimeInterval) -> String? {
        guard duration > 0 else { return nil }

        let minute: TimeInterval = 60
        let hour: TimeInterval = 3600
        let day: TimeInterval = 86_400

        if duration < hour {
            let roundedMinutes = max(1, Int(round(duration / minute)))
            return "\(roundedMinutes)m"
        } else if duration < day {
            let roundedHours = max(1, Int(round(duration / hour)))
            return "\(roundedHours)h"
        } else {
            let roundedDays = max(1, Int(round(duration / day)))
            return "\(roundedDays)d"
        }
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
