import Foundation
import SwiftData

extension PersistentModel {
    func touch() {
        guard let timestamped = self as? any LastModifiedTracking else { return }
        timestamped.lastModifiedAt = .now
    }
}

protocol LastModifiedTracking: PersistentModel {
    var lastModifiedAt: Date { get set }
}
