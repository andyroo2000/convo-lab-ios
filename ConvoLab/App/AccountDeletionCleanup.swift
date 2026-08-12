import Foundation

enum AccountDeletionCleanupDomain: String, CaseIterable, Hashable, Sendable {
    case mediaCache
    case dailyAudio
    case study
    case studyTime
}

struct AccountDeletionCleanupItem: Hashable, Sendable {
    let userID: Int
    let domain: AccountDeletionCleanupDomain

    fileprivate var storedValue: String {
        "\(userID):\(domain.rawValue)"
    }

    fileprivate init?(storedValue: String) {
        let components = storedValue.split(separator: ":", maxSplits: 1)
        guard components.count == 2,
              let userID = Int(components[0]),
              let domain = AccountDeletionCleanupDomain(rawValue: String(components[1]))
        else { return nil }
        self.init(userID: userID, domain: domain)
    }

    init(userID: Int, domain: AccountDeletionCleanupDomain) {
        self.userID = userID
        self.domain = domain
    }
}

struct AccountDeletionCleanupFailure: Equatable, Sendable {
    let item: AccountDeletionCleanupItem

    var userID: Int { item.userID }
    var domain: AccountDeletionCleanupDomain { item.domain }
}

final class AccountDeletionCleanupLedger {
    private static let pendingItemsKey = "ConvoLab.accountDeletion.pendingLocalCleanup"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var pendingItems: [AccountDeletionCleanupItem] {
        storedValues.compactMap(AccountDeletionCleanupItem.init(storedValue:))
    }

    func schedule(userID: Int) {
        var values = Set(storedValues)
        for domain in AccountDeletionCleanupDomain.allCases {
            values.insert(AccountDeletionCleanupItem(userID: userID, domain: domain).storedValue)
        }
        store(values)
    }

    func markCompleted(_ item: AccountDeletionCleanupItem) {
        var values = Set(storedValues)
        values.remove(item.storedValue)
        store(values)
    }

    private var storedValues: [String] {
        defaults.stringArray(forKey: Self.pendingItemsKey) ?? []
    }

    private func store(_ values: Set<String>) {
        defaults.set(values.sorted(), forKey: Self.pendingItemsKey)
    }
}

final class AccountDeletionCleanupCoordinator {
    typealias CleanupOperation = (Int) -> Bool

    private let ledger: AccountDeletionCleanupLedger
    private let operations: [AccountDeletionCleanupDomain: CleanupOperation]

    init(
        ledger: AccountDeletionCleanupLedger,
        operations: [AccountDeletionCleanupDomain: CleanupOperation]
    ) {
        self.ledger = ledger
        self.operations = operations
    }

    func scheduleCleanup(userID: Int) {
        // Persist every domain before the first deletion attempt. A crash or thrown
        // save error can therefore only cause an idempotent retry, never forgotten data.
        ledger.schedule(userID: userID)
    }

    @discardableResult
    func retryPendingCleanup() -> [AccountDeletionCleanupFailure] {
        var failures: [AccountDeletionCleanupFailure] = []
        for item in ledger.pendingItems {
            guard let operation = operations[item.domain] else {
                failures.append(
                    AccountDeletionCleanupFailure(
                        item: item
                    )
                )
                continue
            }
            if !operation(item.userID) {
                failures.append(AccountDeletionCleanupFailure(item: item))
            } else {
                ledger.markCompleted(item)
            }
        }
        return failures
    }
}
