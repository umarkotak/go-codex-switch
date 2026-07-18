import AppKit
import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var accounts: [AccountSnapshot] = []
    @Published private(set) var recommendedEmail: String?
    @Published private(set) var isRefreshing = false
    @Published private(set) var busyEmail: String?
    @Published var statusMessage: String?
    @Published var errorMessage: String?

    private let authStore: AuthStore
    private let api: CodexAPI

    init(authStore: AuthStore = AuthStore(), api: CodexAPI = CodexAPI()) {
        self.authStore = authStore
        self.api = api
    }

    var activeEmail: String? { self.accounts.first(where: \ .isActive)?.email }

    var menuBarIcon: String {
        if self.isRefreshing { return "arrow.triangle.2.circlepath" }
        if self.accounts.contains(where: { $0.primaryWindow?.remainingPercent ?? 0 < 10 }) {
            return "bolt.trianglebadge.exclamationmark.fill"
        }
        return "bolt.horizontal.circle.fill"
    }

    func refresh() async {
        guard !self.isRefreshing else { return }
        self.isRefreshing = true
        defer { self.isRefreshing = false }

        do {
            let stored = try self.authStore.listAccounts()
            var values = stored.map {
                AccountSnapshot(email: $0.email, isActive: $0.isActive, usage: nil, resetCredits: nil, usageError: nil)
            }
            let api = self.api
            await withTaskGroup(of: (Int, UsageResponse?, ResetCreditsResponse?, String?).self) { group in
                for (index, account) in stored.enumerated() {
                    group.addTask {
                        async let credits: ResetCreditsResponse? = try? await api.fetchResetCredits(auth: account.auth)
                        do {
                            let usage = try await api.fetchUsage(auth: account.auth)
                            return (index, usage, await credits, nil)
                        } catch {
                            return (index, nil, await credits, error.localizedDescription)
                        }
                    }
                }
                for await (index, usage, credits, error) in group {
                    values[index].usage = usage
                    values[index].resetCredits = credits
                    values[index].usageError = error
                }
            }
            self.accounts = values
            self.recommendedEmail = RecommendationEngine.recommendedEmail(accounts: values, now: Date())
            if values.isEmpty {
                self.statusMessage = "No saved accounts yet. Sign in to Codex, then choose Save Current."
            }
        } catch {
            self.errorMessage = error.localizedDescription
        }
    }

    func saveCurrent() async {
        await self.perform {
            let email = try self.authStore.saveCurrent()
            self.statusMessage = "Saved \(email)"
            await self.refresh()
        }
    }

    func switchTo(email: String) async {
        guard self.busyEmail == nil else { return }
        self.busyEmail = email
        defer { self.busyEmail = nil }
        do {
            let changed = try self.authStore.load(email: email)
            if !changed {
                self.statusMessage = "\(email) is already active"
                return
            }
            self.statusMessage = "Loaded \(email)"
            if UserDefaults.standard.object(forKey: "restartAfterSwitch") as? Bool ?? true {
                try await CodexRestarter.restart()
                self.statusMessage = "Loaded \(email) and restarted Codex"
            }
            await self.refresh()
        } catch {
            self.errorMessage = error.localizedDescription
        }
    }

    func next() async {
        guard !self.accounts.isEmpty else {
            self.errorMessage = AuthStoreError.noSavedAccounts.localizedDescription
            return
        }
        let target: AccountSnapshot
        if let activeIndex = self.accounts.firstIndex(where: \ .isActive) {
            target = self.accounts[(activeIndex + 1) % self.accounts.count]
        } else {
            target = self.accounts[0]
        }
        await self.switchTo(email: target.email)
    }

    func maxing() async {
        guard let email = self.recommendedEmail else {
            self.errorMessage = "No account has usable usage and reset data."
            return
        }
        await self.switchTo(email: email)
    }

    func logout() async {
        await self.perform {
            let email = try self.authStore.logout()
            try await CodexRestarter.restart()
            self.statusMessage = "Logged out \(email)"
            await self.refresh()
        }
    }

    func restartCodex() async {
        await self.perform {
            try await CodexRestarter.restart()
            self.statusMessage = "Codex restarted"
        }
    }

    func openSavedAccountsFolder() {
        NSWorkspace.shared.open(self.authStore.savedDirectory)
    }

    private func perform(_ action: () async throws -> Void) async {
        do {
            try await action()
        } catch {
            self.errorMessage = error.localizedDescription
        }
    }
}
