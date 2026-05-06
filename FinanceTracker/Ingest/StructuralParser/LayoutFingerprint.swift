import Foundation

struct LayoutFingerprint: Sendable {
    let institutionHint: String
    let headerPattern: String
    let layout: String
    let amountConvention: String?
    let columnRoles: [String: ClosedRange<CGFloat>]
    let sourceFileHash: String
    let transactionCount: Int

    var key: String {
        "\(institutionHint)-\(headerPattern)"
    }
}
