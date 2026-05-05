import Foundation
import os

extension Logger {
    static let app = Logger(subsystem: "com.financeTracker.app", category: "App")
    static let ingest = Logger(subsystem: "com.financeTracker.app", category: "Ingest")
    static let analytics = Logger(subsystem: "com.financeTracker.app", category: "Analytics")
    static let parser = Logger(subsystem: "com.financeTracker.app", category: "Parser")
    static let pipeline = Logger(subsystem: "com.financeTracker.app", category: "Pipeline")
}
