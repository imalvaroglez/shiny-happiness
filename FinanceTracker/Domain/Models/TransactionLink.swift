import CryptoKit
import Foundation
import SwiftData

enum TransactionLinkKind: String, Codable {
    case refund
}

@Model
final class TransactionLink {
    var id: UUID
    var identityKey: String
    var kindRaw: String
    /// Refund links point from the received credit to the purchase.
    var sourceTransactionID: UUID
    var targetTransactionID: UUID
    var lastModifiedAt: Date
    /// A tombstone lets backup merges preserve a user's unlink action.
    var deletedAt: Date?

    init(
        id: UUID,
        identityKey: String,
        kind: TransactionLinkKind,
        sourceTransactionID: UUID,
        targetTransactionID: UUID,
        lastModifiedAt: Date,
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.identityKey = identityKey
        self.kindRaw = kind.rawValue
        self.sourceTransactionID = sourceTransactionID
        self.targetTransactionID = targetTransactionID
        self.lastModifiedAt = lastModifiedAt
        self.deletedAt = deletedAt
    }

    var kind: TransactionLinkKind? { TransactionLinkKind(rawValue: kindRaw) }

    static func stableID(for identityKey: String) -> UUID {
        let digest = Array(SHA256.hash(data: Data(identityKey.utf8)))
        return UUID(uuid: (
            digest[0], digest[1], digest[2], digest[3],
            digest[4], digest[5], digest[6], digest[7],
            digest[8], digest[9], digest[10], digest[11],
            digest[12], digest[13], digest[14], digest[15]
        ))
    }
}
