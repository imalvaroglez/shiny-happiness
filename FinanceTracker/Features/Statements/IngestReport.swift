import Foundation

struct IngestReport: Sendable {
    var fileName: String
    var newTransactions: Int
    var duplicateTransactions: Int
    var errorCount: Int
    var uncategorizedCount: Int
    var errors: [IngestError]

    var totalProcessed: Int {
        newTransactions + duplicateTransactions + errorCount
    }

    init(
        fileName: String,
        newTransactions: Int = 0,
        duplicateTransactions: Int = 0,
        errorCount: Int = 0,
        uncategorizedCount: Int = 0,
        errors: [IngestError] = []
    ) {
        self.fileName = fileName
        self.newTransactions = newTransactions
        self.duplicateTransactions = duplicateTransactions
        self.errorCount = errorCount
        self.uncategorizedCount = uncategorizedCount
        self.errors = errors
    }
}

struct IngestError: Sendable {
    var message: String
    var row: Int?
    var detail: String?

    init(message: String, row: Int? = nil, detail: String? = nil) {
        self.message = message
        self.row = row
        self.detail = detail
    }
}
