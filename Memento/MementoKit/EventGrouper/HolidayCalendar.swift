import Foundation

/// Computes holiday dates per year and matches them against event date ranges,
/// so events shot around a holiday get named "Christmas" instead of "December 24–26".
nonisolated enum HolidayCalendar {

    struct Holiday {
        let name: String
        let date: Date
    }

    /// The best holiday name for an event spanning [start, end], or nil.
    /// Holidays are checked in priority order, so a range covering both
    /// Christmas Eve and Christmas is named "Christmas".
    static func holidayName(overlapping start: Date, _ end: Date, calendar: Calendar = .current) -> String? {
        let startYear = calendar.component(.year, from: start)
        let endYear   = calendar.component(.year, from: end)
        let candidates = (startYear...endYear).flatMap { holidays(year: $0, calendar: calendar) }

        let rangeStart = calendar.startOfDay(for: start)
        let rangeEnd   = calendar.startOfDay(for: end)
        return candidates.first {
            let day = calendar.startOfDay(for: $0.date)
            return day >= rangeStart && day <= rangeEnd
        }?.name
    }

    /// Holidays for one year, in naming-priority order (most distinctive first).
    static func holidays(year: Int, calendar cal: Calendar = .current) -> [Holiday] {
        func fixed(_ name: String, _ month: Int, _ day: Int) -> Holiday? {
            cal.date(from: DateComponents(year: year, month: month, day: day))
                .map { Holiday(name: name, date: $0) }
        }
        func nth(_ name: String, ordinal: Int, weekday: Int, month: Int) -> Holiday? {
            cal.date(from: DateComponents(
                year: year, month: month, weekday: weekday, weekdayOrdinal: ordinal
            )).map { Holiday(name: name, date: $0) }
        }
        func last(_ name: String, weekday: Int, month: Int) -> Holiday? {
            guard let firstOfNext = cal.date(from: DateComponents(
                year: month == 12 ? year + 1 : year,
                month: month == 12 ? 1 : month + 1,
                day: 1
            )), var d = cal.date(byAdding: .day, value: -1, to: firstOfNext) else { return nil }
            while cal.component(.weekday, from: d) != weekday {
                guard let prev = cal.date(byAdding: .day, value: -1, to: d) else { return nil }
                d = prev
            }
            return Holiday(name: name, date: d)
        }

        // Weekday constants: 1 = Sunday … 7 = Saturday (Gregorian).
        return [
            fixed("Christmas", 12, 25),
            nth("Thanksgiving", ordinal: 4, weekday: 5, month: 11),
            easter(year: year, calendar: cal).map { Holiday(name: "Easter", date: $0) },
            fixed("New Year's Day", 1, 1),
            fixed("New Year's Eve", 12, 31),
            fixed("Halloween", 10, 31),
            fixed("Independence Day", 7, 4),
            fixed("Valentine's Day", 2, 14),
            nth("Mother's Day", ordinal: 2, weekday: 1, month: 5),
            nth("Father's Day", ordinal: 3, weekday: 1, month: 6),
            fixed("Christmas Eve", 12, 24),
            last("Memorial Day", weekday: 2, month: 5),
            nth("Labor Day", ordinal: 1, weekday: 2, month: 9),
        ].compactMap { $0 }
    }

    /// Easter Sunday via the anonymous Gregorian computus algorithm.
    static func easter(year: Int, calendar cal: Calendar = .current) -> Date? {
        let a = year % 19
        let b = year / 100
        let c = year % 100
        let d = b / 4
        let e = b % 4
        let f = (b + 8) / 25
        let g = (b - f + 1) / 3
        let h = (19 * a + b - d - g + 15) % 30
        let i = c / 4
        let k = c % 4
        let l = (32 + 2 * e + 2 * i - h - k) % 7
        let m = (a + 11 * h + 22 * l) / 451
        let month = (h + l - 7 * m + 114) / 31
        let day = ((h + l - 7 * m + 114) % 31) + 1
        return cal.date(from: DateComponents(year: year, month: month, day: day))
    }
}
