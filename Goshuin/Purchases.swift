import Combine
import Foundation
import Security
import StoreKit

enum PurchaseKeychain {
    static func save(_ value: Entitlement) throws {
        let data = try JSONEncoder().encode(value)
        let query = key
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            item[kSecValueData as String] = data
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw PurchaseFailure.keychain }
    }

    static func load() throws -> Entitlement? {
        var query = key
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw PurchaseFailure.keychain }
        return try JSONDecoder().decode(Entitlement.self, from: data)
    }

    private static let key: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.hgsldswk.goshuin",
        kSecAttrAccount as String: "entitlement.v1"
    ]
}

enum PurchaseFailure: LocalizedError {
    case unverified, keychain
    var errorDescription: String? { L.t("purchase.error") }
}

actor PurchaseLedger {
    private var stored: Entitlement?

    func open(at now: Date, paid: Bool) throws -> Entitlement {
        var value = try PurchaseKeychain.load() ?? Entitlement(firstOpen: now)
        if paid && value.proStartedAt == nil { value.proStartedAt = now }
        try PurchaseKeychain.save(value)
        stored = value
        return value
    }

    func record(_ transaction: Transaction, now: Date) throws -> Entitlement {
        guard var next = stored else { throw PurchaseFailure.keychain }
        if transaction.productID == Purchases.proID {
            next.purchasedPro = transaction.revocationDate == nil
        } else if transaction.revocationDate == nil && transaction.originalPurchaseDate <= now {
            let date = transaction.originalPurchaseDate
            next.trialClaimedAt = min(next.trialClaimedAt ?? date, date)
        }
        try PurchaseKeychain.save(next)
        stored = next
        return next
    }
}

@MainActor
final class Purchases: ObservableObject {
    nonisolated static let proID = "com.hgsldswk.goshuin.pro"
    nonisolated static let trialID = "com.hgsldswk.goshuin.trial"
    @Published private(set) var entitlement = Entitlement(firstOpen: .distantPast)
    @Published private(set) var products: [String: Product] = [:]
    @Published private(set) var loading = false
    @Published private(set) var purchasing = false
    @Published var message: String?
    @Published private(set) var ready = false
    private var started = false
    private let ledger = PurchaseLedger()

    var hasPro: Bool { Launch.isFree || (ready && entitlement.hasPro(at: Date())) }
    var product: Product? { products[Self.proID] }
    var price: String {
        if AppModel.testing && AppModel.arguments.contains("-paywall") { return "$2.99" }
        return product?.displayPrice ?? L.t("purchase.pricePending")
    }

    func start() async {
        guard !started else { return }
        started = true
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-ui-testing") {
            let date = args.contains("-expired") ? Date().addingTimeInterval(-Entitlement.duration - 5) : Date()
            entitlement = Entitlement(firstOpen: date, proStartedAt: date)
            ready = true
            return
        }
        do {
            entitlement = try await ledger.open(at: Date(), paid: !Launch.isFree)
            ready = true
        } catch {
            message = L.t("purchase.error")
            started = false
            return
        }
        guard !Launch.isFree else { return }
        async let initialProducts: Void = loadProducts()
        do { try await refreshTransactions() }
        catch { message = L.t("purchase.error") }
        await initialProducts
        for await result in Transaction.updates {
            guard case .verified(let transaction) = result,
                  [Self.proID, Self.trialID].contains(transaction.productID) else { continue }
            do {
                try await accept(transaction)
                await transaction.finish()
            } catch {
                message = L.t("purchase.error")
            }
        }
    }

    func loadProducts() async {
        guard !Launch.isFree, !loading, !ProcessInfo.processInfo.arguments.contains("-ui-testing") else { return }
        loading = true
        defer { loading = false }
        do {
            let items = try await Product.products(for: [Self.proID, Self.trialID])
            products = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        } catch {
            message = L.t("purchase.error")
        }
    }

    private func accept(_ transaction: Transaction) async throws {
        entitlement = try await ledger.record(transaction, now: Date())
    }

    private func refreshTransactions() async throws {
        for id in [Self.proID, Self.trialID] {
            guard let result = await Transaction.latest(for: id) else { continue }
            guard case .verified(let transaction) = result else { throw PurchaseFailure.unverified }
            try await accept(transaction)
        }
    }

    func purchase(_ product: Product) async {
        guard !purchasing else { return }
        purchasing = true
        defer { purchasing = false }
        do {
            switch try await product.purchase() {
            case .success(let result):
                guard case .verified(let transaction) = result else { throw PurchaseFailure.unverified }
                try await accept(transaction)
                await transaction.finish()
                message = L.t(product.id == Self.proID ? "purchase.unlocked" : "purchase.claimed")
            case .pending: message = L.t("purchase.pending")
            case .userCancelled: break
            @unknown default: break
            }
        } catch { message = L.t("purchase.error") }
    }

    func restore() async {
        guard !purchasing, !ProcessInfo.processInfo.arguments.contains("-ui-testing") else { return }
        purchasing = true
        defer { purchasing = false }
        do {
            try await AppStore.sync()
            if !ready { entitlement = try await ledger.open(at: Date(), paid: true); ready = true }
            try await refreshTransactions()
            message = L.t(entitlement.purchasedPro || entitlement.trialClaimedAt != nil
                          ? "purchase.restored" : "purchase.none")
        } catch { message = L.t("purchase.error") }
    }
}
