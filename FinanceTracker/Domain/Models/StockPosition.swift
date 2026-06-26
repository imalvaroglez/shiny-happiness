import Foundation
import SwiftData

@Model
final class StockPosition: LastModifiedTracking {
    var id: UUID
    @Relationship(deleteRule: .nullify) var account: Account?
    var emisoraSerie: String
    var name: String?
    var shares: Decimal
    var averageCost: Decimal
    var lastPrice: Decimal?
    var lastPriceAt: Date?
    var createdAt: Date
    var lastModifiedAt: Date = Date.now

    init(
        id: UUID = UUID(),
        account: Account? = nil,
        emisoraSerie: String,
        name: String? = nil,
        shares: Decimal,
        averageCost: Decimal,
        lastPrice: Decimal? = nil,
        lastPriceAt: Date? = nil,
        createdAt: Date = .now
    ) {
        self.id = id
        self.account = account
        self.emisoraSerie = emisoraSerie.uppercased()
        self.name = name
        self.shares = shares
        self.averageCost = averageCost
        self.lastPrice = lastPrice
        self.lastPriceAt = lastPriceAt
        self.createdAt = createdAt
    }
}
