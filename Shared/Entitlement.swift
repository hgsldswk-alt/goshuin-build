import Foundation

struct Entitlement: Codable, Equatable {
    static let duration: TimeInterval = 30 * 86_400
    var firstOpen = Date()
    var trialClaimedAt: Date?
    var purchasedPro = false
    var proStartedAt: Date?

    var trialStart: Date {
        let local = proStartedAt ?? firstOpen
        return trialClaimedAt.map { min($0, local) } ?? local
    }

    var trialEnd: Date { trialStart.addingTimeInterval(Self.duration) }

    func hasPro(at now: Date, free: Bool = Launch.isFree) -> Bool {
        free || purchasedPro || (now >= trialStart && now < trialEnd)
    }

    func remainingDays(at now: Date) -> Int {
        Int(ceil(max(0, trialEnd.timeIntervalSince(now)) / 86_400))
    }
}
