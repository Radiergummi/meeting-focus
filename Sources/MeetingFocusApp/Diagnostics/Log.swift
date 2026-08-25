import OSLog

enum Log {
    private static let subsystem = "me.mazetti.meetingfocus"
    static let detector = Logger(subsystem: subsystem, category: "detector")
    static let accessibility = Logger(subsystem: subsystem, category: "accessibility")
    static let state = Logger(subsystem: subsystem, category: "state")
    static let automation = Logger(subsystem: subsystem, category: "automation")
}
