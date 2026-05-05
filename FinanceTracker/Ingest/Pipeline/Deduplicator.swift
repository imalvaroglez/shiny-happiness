import Foundation

struct Deduplicator {
    struct Result {
        let unique: [Transaction]
        let duplicates: [Transaction]
    }

    static func deduplicate(
        incoming: [Transaction],
        existing: [Transaction]
    ) -> Result {
        var unique: [Transaction] = []
        var duplicates: [Transaction] = []

        for tx in incoming {
            if isDuplicate(tx, against: existing) {
                tx.isDuplicate = true
                duplicates.append(tx)
            } else {
                unique.append(tx)
            }
        }

        return Result(unique: unique, duplicates: duplicates)
    }

    private static func isDuplicate(_ tx: Transaction, against existing: [Transaction]) -> Bool {
        let calendar = Calendar.current

        return existing.contains { candidate in
            guard tx.amount == candidate.amount else { return false }

            let daysDiff = calendar.dateComponents([.day], from: candidate.postedAt, to: tx.postedAt).day ?? 999
            guard abs(daysDiff) <= 1 else { return false }

            return similarDescription(tx.descriptionRaw, candidate.descriptionRaw)
        }
    }

    private static func similarDescription(_ a: String, _ b: String) -> Bool {
        let aNorm = a.lowercased().trimmingCharacters(in: .whitespaces)
        let bNorm = b.lowercased().trimmingCharacters(in: .whitespaces)

        if aNorm == bNorm { return true }

        let shorter = aNorm.count < bNorm.count ? aNorm : bNorm
        let longer = aNorm.count < bNorm.count ? bNorm : aNorm
        if shorter.count > 5 && longer.contains(shorter) {
            return true
        }

        return false
    }
}
