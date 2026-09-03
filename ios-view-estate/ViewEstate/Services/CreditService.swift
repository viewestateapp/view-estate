import Foundation

/// The only authorised way to change a credit balance.
///
/// Rules encoded here:
/// - the UI can never mutate a wallet directly;
/// - every movement produces a `CreditTransaction`;
/// - included credits are consumed before purchased credits;
/// - duplicated payment events (same idempotency key) never credit twice;
/// - standard photography/HDR operations never reach this service at all.
struct CreditService: Sendable {
    struct Result: Sendable {
        let wallet: CreditWallet
        let transaction: CreditTransaction?
        let duplicateIgnored: Bool
    }

    enum Failure: Error, Sendable {
        case insufficientCredits(required: Int, available: Int)
    }

    /// Grants the monthly allocation that comes with the subscription.
    static func allocatePlanCredits(
        wallet: CreditWallet,
        amount: Int,
        label: String,
        existing: [CreditTransaction],
        idempotencyKey: String
    ) -> Result {
        guard !existing.contains(where: { $0.idempotencyKey == idempotencyKey }) else {
            return Result(wallet: wallet, transaction: nil, duplicateIgnored: true)
        }
        var updated = wallet
        updated.authorizedApply(.init(included: amount, purchased: 0))
        let transaction = CreditTransaction(
            id: UUID(),
            type: .planMonthlyAllocation,
            amount: amount,
            label: label,
            createdAt: .now,
            idempotencyKey: idempotencyKey
        )
        return Result(wallet: updated, transaction: transaction, duplicateIgnored: false)
    }

    /// Applied only after an authorised payment event has been confirmed.
    static func applyConfirmedPurchase(
        wallet: CreditWallet,
        package: CreditPackage,
        label: String,
        existing: [CreditTransaction],
        idempotencyKey: String
    ) -> Result {
        guard !existing.contains(where: { $0.idempotencyKey == idempotencyKey }) else {
            return Result(wallet: wallet, transaction: nil, duplicateIgnored: true)
        }
        var updated = wallet
        updated.authorizedApply(.init(included: 0, purchased: package.credits))
        let transaction = CreditTransaction(
            id: UUID(),
            type: .creditPackPurchase,
            amount: package.credits,
            label: label,
            createdAt: .now,
            idempotencyKey: idempotencyKey
        )
        return Result(wallet: updated, transaction: transaction, duplicateIgnored: false)
    }

    /// Consumes credits for an advanced AI operation. Included balance is spent first.
    static func consume(
        wallet: CreditWallet,
        credits: Int,
        label: String
    ) throws -> Result {
        guard wallet.total >= credits else {
            throw Failure.insufficientCredits(required: credits, available: wallet.total)
        }
        let fromIncluded = min(wallet.includedCredits, credits)
        let fromPurchased = credits - fromIncluded
        var updated = wallet
        updated.authorizedApply(.init(included: -fromIncluded, purchased: -fromPurchased))
        let transaction = CreditTransaction(
            id: UUID(),
            type: .aiOperation,
            amount: -credits,
            label: label,
            createdAt: .now,
            idempotencyKey: nil
        )
        return Result(wallet: updated, transaction: transaction, duplicateIgnored: false)
    }

    /// Releases credits reserved for an AI operation that ultimately failed.
    static func refund(
        wallet: CreditWallet,
        credits: Int,
        label: String
    ) -> Result {
        var updated = wallet
        updated.authorizedApply(.init(included: credits, purchased: 0))
        let transaction = CreditTransaction(
            id: UUID(),
            type: .refund,
            amount: credits,
            label: label,
            createdAt: .now,
            idempotencyKey: nil
        )
        return Result(wallet: updated, transaction: transaction, duplicateIgnored: false)
    }
}
