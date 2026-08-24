import AppKit
import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var accounts: [AccountSnapshot] = []
    @Published private(set) var claudeAccounts: [ClaudeAccountSnapshot] = []
    @Published private(set) var claudeRecommendedEmail: String?
    @Published private(set) var recommendedEmail: String?
    @Published private(set) var isRefreshing = false
    @Published private(set) var isRefreshingExpired = false
    @Published private(set) var busyEmail: String?
    @Published private(set) var busyClaudeEmail: String?
    @Published var statusMessage: String?
    @Published var errorMessage: String?

    private let authStore: AuthStore
    private let api: CodexAPI
    private let claudeAuthStore: ClaudeAuthStore
    private let claudeAPI: ClaudeAPI

    init(
        authStore: AuthStore = AuthStore(),
        api: CodexAPI = CodexAPI(),
        claudeAuthStore: ClaudeAuthStore = ClaudeAuthStore(),
        claudeAPI: ClaudeAPI = ClaudeAPI())
    {
        self.authStore = authStore
        self.api = api
        self.claudeAuthStore = claudeAuthStore
        self.claudeAPI = claudeAPI
    }

    var activeEmail: String? { self.accounts.first(where: \ .isActive)?.email }
    var activeClaudeEmail: String? { self.claudeAccounts.first(where: \ .isActive)?.email }

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
            await self.refreshClaudeAccounts()
            if values.isEmpty {
                self.statusMessage = "No saved accounts yet. Sign in to Codex, then choose Save Current."
            }
        } catch {
            self.errorMessage = error.localizedDescription
        }
    }

    func refreshOnOpen() async {
        if self.accounts.isEmpty {
            await self.refresh()
        } else {
            await self.refreshActiveUsage()
            await self.refreshActiveClaudeUsage()
        }
    }

    func refreshClaudeAccounts() async {
        do {
            guard let credentials = try self.claudeAuthStore.currentCredentials() else {
                self.claudeAccounts = []
                self.claudeRecommendedEmail = nil
                return
            }
            let activeEmail = try? await self.claudeAPI.fetchEmail(credentials: credentials)
            let stored = try self.claudeAuthStore.listAccounts(
                activeEmail: activeEmail,
                activeToken: credentials.accessToken)
            var values = stored.map {
                ClaudeAccountSnapshot(
                    email: $0.email,
                    isActive: $0.isActive,
                    usage: nil,
                    usageError: nil)
            }
            let api = self.claudeAPI
            await withTaskGroup(of: (Int, ClaudeUsageResponse?, String?).self) { group in
                for (index, account) in stored.enumerated() {
                    group.addTask {
                        do {
                            return (index, try await api.fetchUsage(credentials: account.credentials), nil)
                        } catch {
                            return (index, nil, error.localizedDescription)
                        }
                    }
                }
                for await (index, usage, error) in group {
                    values[index].usage = usage
                    values[index].usageError = error
                }
            }
            self.claudeAccounts = values
            self.claudeRecommendedEmail = ClaudeRecommendationEngine.recommendedEmail(
                accounts: values,
                now: Date())
        } catch {
            self.errorMessage = error.localizedDescription
        }
    }

    func refreshActiveClaudeUsage() async {
        guard self.busyClaudeEmail == nil,
              let activeEmail = self.activeClaudeEmail,
              let index = self.claudeAccounts.firstIndex(where: { $0.email == activeEmail })
        else {
            await self.refreshClaudeAccounts()
            return
        }

        do {
            guard let credentials = try self.claudeAuthStore.currentCredentials() else {
                await self.refreshClaudeAccounts()
                return
            }
            do {
                self.claudeAccounts[index].usage = try await self.claudeAPI.fetchUsage(credentials: credentials)
                self.claudeAccounts[index].usageError = nil
            } catch {
                self.claudeAccounts[index].usageError = error.localizedDescription
            }
            self.claudeRecommendedEmail = ClaudeRecommendationEngine.recommendedEmail(
                accounts: self.claudeAccounts,
                now: Date())
        } catch {
            self.errorMessage = error.localizedDescription
        }
    }

    func refreshActiveUsage() async {
        guard !self.isRefreshing, !self.isRefreshingExpired, self.busyEmail == nil else { return }

        do {
            guard let active = try self.authStore.currentAccount() else { return }
            guard active.email == self.activeEmail,
                  self.accounts.contains(where: { $0.email == active.email })
            else {
                await self.refresh()
                return
            }

            self.isRefreshing = true
            defer { self.isRefreshing = false }

            let usageResult: Result<UsageResponse, Error>
            do {
                usageResult = .success(try await self.api.fetchUsage(auth: active.auth))
            } catch {
                usageResult = .failure(error)
            }

            guard try self.authStore.currentEmail() == active.email,
                  let currentIndex = self.accounts.firstIndex(where: { $0.email == active.email })
            else {
                self.isRefreshing = false
                await self.refresh()
                return
            }
            switch usageResult {
            case let .success(usage):
                self.accounts[currentIndex].usage = usage
                self.accounts[currentIndex].usageError = nil
            case let .failure(error):
                self.accounts[currentIndex].usageError = error.localizedDescription
            }
            self.recommendedEmail = RecommendationEngine.recommendedEmail(
                accounts: self.accounts,
                now: Date())
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

    func saveCurrentClaude() async {
        do {
            guard let credentials = try self.claudeAuthStore.currentCredentials() else {
                self.errorMessage = "Please sign in to Claude Code first."
                return
            }
            guard let email = try await self.claudeAPI.fetchEmail(credentials: credentials), !email.isEmpty else {
                self.errorMessage = "Claude did not return an account email."
                return
            }
            try self.claudeAuthStore.saveCurrent(email: email)
            self.statusMessage = "Saved Claude account \(email)"
            await self.refreshClaudeAccounts()
        } catch {
            self.errorMessage = error.localizedDescription
        }
    }

    func switchClaudeTo(email: String) async {
        guard self.busyClaudeEmail == nil else { return }
        self.busyClaudeEmail = email
        defer { self.busyClaudeEmail = nil }

        do {
            guard let current = try self.claudeAuthStore.currentCredentials() else {
                throw ClaudeAuthStoreError.noSavedAccounts
            }
            guard let activeEmail = try await self.claudeAPI.fetchEmail(credentials: current), !activeEmail.isEmpty else {
                self.errorMessage = "Save the current Claude account before switching."
                return
            }
            try self.claudeAuthStore.saveCurrent(email: activeEmail)
            let changed = try self.claudeAuthStore.load(email: email, activeEmail: activeEmail)
            self.statusMessage = changed ? "Loaded Claude account \(email)" : "\(email) is already active"
            await self.refreshClaudeAccounts()
        } catch {
            self.errorMessage = error.localizedDescription
        }
    }

    func nextClaude() async {
        guard !self.claudeAccounts.isEmpty else {
            self.errorMessage = ClaudeAuthStoreError.noSavedAccounts.localizedDescription
            return
        }
        let target: ClaudeAccountSnapshot
        if let activeIndex = self.claudeAccounts.firstIndex(where: \ .isActive) {
            target = self.claudeAccounts[(activeIndex + 1) % self.claudeAccounts.count]
        } else {
            target = self.claudeAccounts[0]
        }
        await self.switchClaudeTo(email: target.email)
    }

    func maxingClaude() async {
        guard let email = self.claudeRecommendedEmail else {
            self.errorMessage = "No Claude account has usable session quota data."
            return
        }
        await self.switchClaudeTo(email: email)
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

    func refreshExpired() async {
        guard !self.isRefreshingExpired, !self.isRefreshing, self.busyEmail == nil else { return }
        self.isRefreshingExpired = true
        defer { self.isRefreshingExpired = false }

        do {
            try self.authStore.syncActiveAccountIfSaved()
            let accounts = try self.authStore.listAccounts()
            let expired = accounts.filter { $0.auth.needsRefresh() }
            guard !expired.isEmpty else {
                self.statusMessage = "All saved accounts already have fresh credentials."
                return
            }

            var refreshedEmails: [String] = []
            var failures: [String] = []
            for account in expired {
                do {
                    let refreshed = try await self.api.refreshAuth(account.auth)
                    try self.authStore.saveRefreshed(
                        refreshed,
                        for: account.email,
                        isActive: account.isActive)
                    refreshedEmails.append(account.email)
                } catch {
                    failures.append("\(account.email): \(error.localizedDescription)")
                }
            }

            await self.refresh()
            var lines = ["Refreshed \(refreshedEmails.count) of \(expired.count) expired account(s)."]
            if !failures.isEmpty {
                lines.append("")
                lines.append(contentsOf: failures)
            }
            self.statusMessage = lines.joined(separator: "\n")
        } catch {
            self.errorMessage = error.localizedDescription
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
