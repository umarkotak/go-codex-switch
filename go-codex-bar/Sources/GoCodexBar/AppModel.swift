import AppKit
import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var accounts: [AccountSnapshot] = []
    @Published private(set) var claudeAccounts: [ClaudeAccountSnapshot] = []
    @Published private(set) var claudeRecommendedEmail: String?
    /// True when Claude quota comes from the Claude desktop app session (quota only, not switchable).
    @Published private(set) var isClaudeDesktopSession = false
    @Published private(set) var recommendedEmail: String?
    @Published private(set) var codexResetStatus: CodexResetsResponse?
    @Published private(set) var codexResetStatusError: CodexResetStatusError?
    @Published private(set) var isRefreshing = false
    @Published private(set) var isRefreshingCodexResetStatus = false
    @Published private(set) var isRefreshingExpired = false
    @Published private(set) var refreshingEmail: String?
    @Published private(set) var refreshingClaudeEmail: String?
    @Published private(set) var busyEmail: String?
    @Published private(set) var busyClaudeEmail: String?
    @Published var statusMessage: String?
    @Published var errorMessage: String?

    private let authStore: AuthStore
    private let api: CodexAPI
    private let claudeAuthStore: ClaudeAuthStore
    private let claudeAPI: ClaudeAPI
    private let claudeDesktopProfiles: ClaudeDesktopProfileStore
    private let claudeDesktopLauncher: ClaudeDesktopLauncher
    private var claudeDesktopProfileByEmail: [String: ClaudeDesktopProfile] = [:]
    @Published private(set) var claudeRefreshCount = 0
    private static let hiddenClaudeProfilesKey = "hiddenClaudeDesktopProfiles"
    @Published private(set) var hiddenClaudeProfiles =
        UserDefaults.standard.stringArray(forKey: hiddenClaudeProfilesKey) ?? []
    private let claudeWebAPI: ClaudeWebAPI
    private let codexResetsAPI: CodexResetsAPI

    init(
        authStore: AuthStore = AuthStore(),
        api: CodexAPI = CodexAPI(),
        claudeAuthStore: ClaudeAuthStore = ClaudeAuthStore(),
        claudeAPI: ClaudeAPI = ClaudeAPI(),
        claudeDesktopProfiles: ClaudeDesktopProfileStore = ClaudeDesktopProfileStore(),
        claudeDesktopLauncher: ClaudeDesktopLauncher = ClaudeDesktopLauncher(),
        claudeWebAPI: ClaudeWebAPI = ClaudeWebAPI(),
        codexResetsAPI: CodexResetsAPI = CodexResetsAPI())
    {
        self.authStore = authStore
        self.api = api
        self.claudeAuthStore = claudeAuthStore
        self.claudeAPI = claudeAPI
        self.claudeDesktopProfiles = claudeDesktopProfiles
        self.claudeDesktopLauncher = claudeDesktopLauncher
        self.claudeWebAPI = claudeWebAPI
        self.codexResetsAPI = codexResetsAPI
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
        defer {
            self.isRefreshing = false
            self.refreshingEmail = nil
        }

        await self.refreshCodexResetStatus()

        do {
            let stored = try self.authStore.listAccounts()
            let previousByEmail = Dictionary(uniqueKeysWithValues: self.accounts.map { ($0.email, $0) })
            var values = stored.map { account in
                let previous = previousByEmail[account.email]
                return AccountSnapshot(
                    email: account.email,
                    isActive: account.isActive,
                    usage: previous?.usage,
                    resetCredits: previous?.resetCredits,
                    usageError: nil)
            }
            // Refresh one account at a time. The active account always goes first so
            // opening the panel shows the currently selected account as soon as possible.
            let refreshOrder = stored.indices.sorted { lhs, rhs in
                if stored[lhs].isActive != stored[rhs].isActive {
                    return stored[lhs].isActive
                }
                return lhs < rhs
            }
            self.accounts = values
            for index in refreshOrder {
                let account = stored[index]
                self.refreshingEmail = account.email
                do {
                    values[index].usage = try await self.api.fetchUsage(auth: account.auth)
                    values[index].usageError = nil
                } catch {
                    values[index].usageError = error.localizedDescription
                }
                values[index].resetCredits = try? await self.api.fetchResetCredits(auth: account.auth)
                self.accounts = values
            }
            self.refreshingEmail = nil
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
        await self.refresh()
    }

    private func refreshCodexResetStatus() async {
        guard !self.isRefreshingCodexResetStatus else { return }
        self.isRefreshingCodexResetStatus = true
        defer { self.isRefreshingCodexResetStatus = false }

        do {
            self.codexResetStatus = try await self.codexResetsAPI.fetchStatus()
            self.codexResetStatusError = nil
        } catch {
            self.codexResetStatus = nil
            let apiError = error as? CodexResetsAPIError
            self.codexResetStatusError = CodexResetStatusError(
                message: error.localizedDescription,
                responseCode: apiError?.responseCode)
        }
    }

    func dismissCodexResetStatusError() {
        self.codexResetStatusError = nil
    }

    func refreshClaudeAccounts() async {
        self.claudeRefreshCount += 1
        defer {
            self.claudeRefreshCount -= 1
            self.refreshingClaudeEmail = nil
        }
        do {
            guard let credentials = try self.claudeAuthStore.currentCredentials() else {
                await self.refreshClaudeDesktopAccounts()
                return
            }
            self.isClaudeDesktopSession = false
            let activeEmail = try? await self.claudeAPI.fetchEmail(credentials: credentials)
            let stored = try self.claudeAuthStore.listAccounts(
                activeEmail: activeEmail,
                activeToken: credentials.accessToken)
            let previousByEmail = Dictionary(uniqueKeysWithValues: self.claudeAccounts.map { ($0.email, $0) })
            var values = stored.map { account in
                ClaudeAccountSnapshot(
                    email: account.email,
                    isActive: account.isActive,
                    usage: previousByEmail[account.email]?.usage,
                    usageError: nil)
            }
            // Match Codex refresh behavior: active first, then each remaining account.
            let refreshOrder = stored.indices.sorted { lhs, rhs in
                if stored[lhs].isActive != stored[rhs].isActive {
                    return stored[lhs].isActive
                }
                return lhs < rhs
            }
            self.claudeAccounts = values
            for index in refreshOrder {
                self.refreshingClaudeEmail = stored[index].email
                do {
                    values[index].usage = try await self.claudeAPI.fetchUsage(
                        credentials: stored[index].credentials)
                    values[index].usageError = nil
                } catch {
                    values[index].usageError = error.localizedDescription
                }
                self.claudeAccounts = values
            }
            self.refreshingClaudeEmail = nil
            self.claudeAccounts = values
            self.claudeRecommendedEmail = ClaudeRecommendationEngine.recommendedEmail(
                accounts: values,
                now: Date())
        } catch {
            self.errorMessage = error.localizedDescription
        }
    }

    /// Fallback for people who use the Claude desktop app instead of Claude Code. Every desktop profile
    /// (the normal Claude folder plus the ones created here) is read for its signed-in account and quota.
    private func refreshClaudeDesktopAccounts() async {
        defer { self.refreshingClaudeEmail = nil }
        let profiles = self.claudeDesktopProfiles.listProfiles().filter {
            !self.hiddenClaudeProfiles.contains($0.name)
        }
        guard !profiles.isEmpty else {
            self.isClaudeDesktopSession = false
            self.claudeAccounts = []
            self.claudeRecommendedEmail = nil
            self.claudeDesktopProfileByEmail = [:]
            return
        }

        let instances = self.claudeDesktopLauncher.runningInstances()
        let previousByEmail = Dictionary(
            self.claudeAccounts.map { ($0.email, $0) },
            uniquingKeysWith: { first, _ in first })
        var values: [ClaudeAccountSnapshot] = []
        var profileByEmail: [String: ClaudeDesktopProfile] = [:]
        var reportedError = false

        for profile in profiles {
            let sessionKey: String
            do {
                sessionKey = try ClaudeDesktopSessionReader(dataDirectory: profile.dataDirectory).readSessionKey()
            } catch ClaudeDesktopSessionError.cookieStoreMissing, ClaudeDesktopSessionError.noSessionKey {
                continue // Not signed in yet (for example, a profile whose sign-in is still in progress).
            } catch {
                if !reportedError {
                    self.errorMessage = error.localizedDescription
                    reportedError = true
                }
                continue
            }

            let knownEmail = self.claudeDesktopProfileByEmail.first { $0.value.name == profile.name }?.key
            self.refreshingClaudeEmail = knownEmail
            let fetchedEmail = try? await self.claudeWebAPI.fetchEmail(sessionKey: sessionKey)
            let email = fetchedEmail ?? knownEmail ?? "Claude (\(profile.name))"
            guard profileByEmail[email] == nil else { continue } // Two profiles signed in to one account.

            var snapshot = ClaudeAccountSnapshot(
                email: email,
                isActive: ClaudeDesktopLauncher.instance(for: profile, in: instances) != nil,
                usage: previousByEmail[email]?.usage,
                usageError: nil)
            profileByEmail[email] = profile
            self.refreshingClaudeEmail = email

            do {
                snapshot.usage = try await self.claudeWebAPI.fetchUsage(sessionKey: sessionKey)
            } catch {
                snapshot.usageError = error.localizedDescription
            }
            values.append(snapshot)
        }

        // Keep existing cards visible until every desktop profile has been checked.
        self.claudeDesktopProfileByEmail = profileByEmail
        self.isClaudeDesktopSession = !values.isEmpty
        self.claudeAccounts = values
        self.claudeRecommendedEmail = values.isEmpty
            ? nil
            : ClaudeRecommendationEngine.recommendedEmail(accounts: values, now: Date())
    }

    /// Creates a new empty Claude profile and opens it so the next account can be signed in.
    func addClaudeProfile() async {
        guard self.busyClaudeEmail == nil else { return }
        do {
            let profile = try self.claudeDesktopProfiles.createProfile(named: self.claudeDesktopProfiles.nextProfileName())
            try self.claudeDesktopLauncher.open(profile)
            self.statusMessage = "Opened a new Claude window. Sign in with the emailed code, then reopen this menu."
        } catch {
            self.errorMessage = error.localizedDescription
        }
    }

    private func switchClaudeDesktop(to email: String) async {
        guard let profile = self.claudeDesktopProfileByEmail[email] else {
            self.errorMessage = "No Claude profile was found for \(email)."
            return
        }
        self.busyClaudeEmail = email
        defer { self.busyClaudeEmail = nil }
        do {
            try self.claudeDesktopLauncher.open(profile)
            self.statusMessage = "Opened Claude as \(email)"
            try? await Task.sleep(for: .seconds(2))
            await self.refreshClaudeAccounts()
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

        self.claudeRefreshCount += 1
        defer { self.claudeRefreshCount -= 1 }
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

    var canRemoveCodexAccount: Bool {
        !self.isRefreshing && !self.isRefreshingExpired && self.busyEmail == nil
    }

    var canRemoveClaudeAccount: Bool {
        self.claudeRefreshCount == 0 && self.busyClaudeEmail == nil
    }

    func removeCodexAccount(email: String) {
        guard self.canRemoveCodexAccount, self.accounts.contains(where: { $0.email == email }) else { return }
        do {
            try self.authStore.removeSavedAccount(email: email)
            self.accounts.removeAll { $0.email == email }
            self.recommendedEmail = RecommendationEngine.recommendedEmail(accounts: self.accounts, now: Date())
        } catch {
            self.errorMessage = error.localizedDescription
        }
    }

    func removeClaudeAccount(email: String) {
        guard self.canRemoveClaudeAccount, self.claudeAccounts.contains(where: { $0.email == email }) else { return }
        do {
            if let profile = self.claudeDesktopProfileByEmail[email], self.isClaudeDesktopSession {
                self.hiddenClaudeProfiles.append(profile.name)
                UserDefaults.standard.set(self.hiddenClaudeProfiles, forKey: Self.hiddenClaudeProfilesKey)
                self.claudeDesktopProfileByEmail.removeValue(forKey: email)
            } else {
                try self.claudeAuthStore.removeSavedAccount(email: email)
            }
            self.claudeAccounts.removeAll { $0.email == email }
            self.claudeRecommendedEmail = ClaudeRecommendationEngine.recommendedEmail(
                accounts: self.claudeAccounts, now: Date())
        } catch {
            self.errorMessage = error.localizedDescription
        }
    }

    func restoreHiddenClaudeProfiles() async {
        guard self.canRemoveClaudeAccount else { return }
        self.hiddenClaudeProfiles = []
        UserDefaults.standard.removeObject(forKey: Self.hiddenClaudeProfilesKey)
        await self.refreshClaudeAccounts()
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
                self.statusMessage = "Loaded \(email) and restarted ChatGPT"
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
        if self.isClaudeDesktopSession {
            self.statusMessage = "Claude desktop accounts are detected automatically. Use Add Claude Profile for another one."
            return
        }
        do {
            guard let credentials = try self.claudeAuthStore.currentCredentials() else {
                self.errorMessage = "Sign in to Claude Code first, or open the Claude desktop app and sign in."
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
        if self.isClaudeDesktopSession {
            guard self.busyClaudeEmail == nil else { return }
            await self.switchClaudeDesktop(to: email)
            return
        }
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
            self.statusMessage = "ChatGPT restarted"
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
