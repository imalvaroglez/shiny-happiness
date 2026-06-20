import Foundation
import os

extension Logger {
    static let app = Logger(subsystem: "com.financeTracker.app", category: "App")
    static let pipeline = Logger(subsystem: "com.financeTracker.app", category: "Pipeline")
}
