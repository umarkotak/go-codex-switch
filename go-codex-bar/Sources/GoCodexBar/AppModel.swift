import AppKit
import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var accounts: [AccountSnapshot] = []
    @Published private(set) var claudeAccounts: [ClaudeAccountSnapshot] = []
    @Published private(set) var claudeRecommendedEmail: String?
    /// Claude desktop app accounts, one per profile folder. Kept separate from Claude Code accounts.
    @Published private(set) var claudeDesktopAccounts: [ClaudeAccountSnapshot] = []
    @Published private(set) var claudeDesktopRecommendedEmail: String?
    @Published private(set) var claudeDesktopError: String?
    @Published private(set) var geminiAccounts: [GeminiAccountSnapshot] = []
    @Published private(set) var geminiError: String?
    @Published private(set) var isRefreshingGemini = false
    @Published private(set) var recommendedEmail: String?
    @Published private(set) var codexResetStatus: CodexResetsResponse?
    @Published private(set) var codexResetStatusError: CodexResetStatusError?
    @Published private(set) var isRefreshing = false
    @Published private(set) var isRefreshingCodexResetStatus = false
    @Published private(set) var isRefreshingExpired = false
    @Published private(set) var refreshingEmail: String?
    @Published private(set) var refreshingClaudeEmail: String?
    @Published private(set) var refreshingClaudeDesktopEmail: String?
    @Published private(set) var busyEmail: String?
    @Published private(set) var busyClaudeEmail: String?
    @Published private(set) var busyClaudeDesktopEmail: String?
    @Published var statusMessage: String?
    @Published var errorMessage: String?

    private let authStore: AuthStore
    private let api: CodexAPI
    private let claudeAuthStore: ClaudeAuthStore
    private let claudeAPI: ClaudeAPI
    private let claudeDesktopProfiles: ClaudeDesktopProfileStore
    private let claudeDesktopLauncher: ClaudeDesktopLauncher
    private var claudeDesktopProfileByEmail: [String: ClaudeDesktopProfile] = [:]
    /// Signed-in Claude Code logins that have no saved copy, so switching to them still works.
    private var claudeLiveDataByEmail: [String: Data] = [:]
    @Published private(set) var claudeRefreshCount = 0
    @Published private(set) var claudeDesktopRefreshCount = 0
    private static let hiddenClaudeProfilesKey = "hiddenClaudeDesktopProfiles"
    @Published private(set) var hiddenClaudeProfiles =
        UserDefaults.standard.stringArray(forKey: hiddenClaudeProfilesKey) ?? []
    private let claudeWebAPI: ClaudeWebAPI
    private let codexResetsAPI: CodexResetsAPI
    private let geminiAPI: GeminiAPI

    init(
        authStore: AuthStore = AuthStore(),
        api: CodexAPI = CodexAPI(),
        claudeAuthStore: ClaudeAuthStore = ClaudeAuthStore(),
        claudeAPI: ClaudeAPI = ClaudeAPI(),
        claudeDesktopProfiles: ClaudeDesktopProfileStore = ClaudeDesktopProfileStore(),
        claudeDesktopLauncher: ClaudeDesktopLauncher = ClaudeDesktopLauncher(),
        claudeWebAPI: ClaudeWebAPI = ClaudeWebAPI(),
        codexResetsAPI: CodexResetsAPI = CodexResetsAPI(),
        geminiAPI: GeminiAPI = GeminiAPI())
    {
        self.authStore = authStore
        self.api = api
        self.claudeAuthStore = claudeAuthStore
        self.claudeAPI = claudeAPI
        self.claudeDesktopProfiles = claudeDesktopProfiles
        self.claudeDesktopLauncher = claudeDesktopLauncher
        self.claudeWebAPI = claudeWebAPI
        self.codexResetsAPI = codexResetsAPI
        self.geminiAPI = geminiAPI
    }

    var activeEmail: String? { self.accounts.first(where: \ .isActive)?.email }
    var activeClaudeEmail: String? { self.claudeAccounts.first(where: \ .isActive)?.email }
    var activeClaudeDesktopEmail: String? { self.claudeDesktopAccounts.first(where: \ .isActive)?.email }

    var menuBarIcon: String {
        if self.isRefreshing { return "arrow.triangle.2.circlepath" }
        if self.accounts.contains(where: { $0.primaryWindow?.remainingPercent ?? 0 < 10 }) {
            return "bolt.trianglebadge.exclamationmark.fill"
        }
        return "bolt.horizontal.circle.fill"
    }

    func refresh() async {
        async let claude: Void = self.refreshClaudeAccounts()
        async let desktop: Void = self.refreshClaudeDesktopAccounts()
        async let gemini: Void = self.refreshGeminiAccounts()
        await self.refreshCodexAccounts()
        await claude
        await desktop
        await gemini
    }

    func refreshGeminiAccounts() async {
        guard !self.isRefreshingGemini else { return }
        self.isRefreshingGemini = true
        defer { self.isRefreshingGemini = false }
        do {
            self.geminiAccounts = try await self.geminiAPI.fetch(source: .auto)
            self.geminiError = nil
        } catch is CancellationError {
            return
        } catch {
            // An account may have changed since the previous refresh; never leave its quota looking current.
            self.geminiAccounts = []
            self.geminiError = (error as? GeminiUsageError)?.localizedDescription
                ?? "Could not check Gemini usage. Open Antigravity or sign in with `agy`, then refresh."
        }
    }

    func openAntigravity() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.antigravity") else {
            self.errorMessage = "Antigravity is not installed. Install Antigravity and sign in to see Gemini usage."
            return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    private func refreshCodexAccounts() async {
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
        let store = self.claudeAuthStore
        // `security` runs as a child process; keep it off the main thread.
        let live = await Task.detached { store.liveLogins() }.value

        struct Entry {
            let email: String
            var isActive: Bool
            var credentials: ClaudeOAuthCredentials
            var detail: String
            var isSaved: Bool
        }
        var entries: [Entry] = []
        var liveData: [String: Data] = [:]
        var activeEmail: String?
        var activeToken: String?

        for (index, login) in live.enumerated() {
            let fetched = try? await self.claudeAPI.fetchEmail(credentials: login.credentials)
            let email = (fetched?.isEmpty == false ? fetched : nil) ?? "Claude Code login \(index + 1)"
            guard !entries.contains(where: { $0.email == email }) else { continue }
            if login.isDefault {
                activeEmail = email
                activeToken = login.credentials.accessToken
            }
            liveData[email] = login.data
            entries.append(Entry(
                email: email,
                isActive: login.isDefault,
                credentials: login.credentials,
                detail: login.label,
                isSaved: false))
        }

        do {
            let stored = try store.listAccounts(activeEmail: activeEmail, activeToken: activeToken)
            for account in stored {
                if let index = entries.firstIndex(where: { $0.email == account.email }) {
                    entries[index].isSaved = true
                    entries[index].detail += " · saved"
                } else {
                    entries.append(Entry(
                        email: account.email,
                        isActive: account.isActive,
                        credentials: account.credentials,
                        detail: "Saved",
                        isSaved: true))
                }
            }
        } catch {
            self.errorMessage = error.localizedDescription
        }

        self.claudeLiveDataByEmail = liveData
        let previousByEmail = Dictionary(
            self.claudeAccounts.map { ($0.email, $0) },
            uniquingKeysWith: { first, _ in first })
        var values = entries.map { entry in
            ClaudeAccountSnapshot(
                email: entry.email,
                isActive: entry.isActive,
                usage: previousByEmail[entry.email]?.usage,
                usageError: nil,
                detail: entry.detail,
                isSaved: entry.isSaved)
        }
        // Match Codex refresh behavior: active first, then each remaining account.
        let refreshOrder = entries.indices.sorted { lhs, rhs in
            entries[lhs].isActive != entries[rhs].isActive ? entries[lhs].isActive : lhs < rhs
        }
        self.claudeAccounts = values
        for index in refreshOrder {
            self.refreshingClaudeEmail = entries[index].email
            do {
                values[index].usage = try await self.claudeAPI.fetchUsage(credentials: entries[index].credentials)
                values[index].usageError = nil
            } catch {
                values[index].usageError = error.localizedDescription
            }
            self.claudeAccounts = values
        }
        self.refreshingClaudeEmail = nil
        self.claudeAccounts = values
        self.claudeRecommendedEmail = values.isEmpty
            ? nil
            : ClaudeRecommendationEngine.recommendedEmail(accounts: values, now: Date())
    }

    /// Every Claude desktop profile (the normal Claude folder plus the ones created here) is read for its
    /// signed-in account and quota. This is independent of Claude Code.
    func refreshClaudeDesktopAccounts() async {
        self.claudeDesktopRefreshCount += 1
        defer {
            self.claudeDesktopRefreshCount -= 1
            self.refreshingClaudeDesktopEmail = nil
        }
        self.claudeDesktopError = nil
        let profiles = self.claudeDesktopProfiles.listProfiles().filter {
            !self.hiddenClaudeProfiles.contains($0.name)
        }
        guard !profiles.isEmpty else {
            self.claudeDesktopAccounts = []
            self.claudeDesktopRecommendedEmail = nil
            self.claudeDesktopProfileByEmail = [:]
            return
        }

        let instances = self.claudeDesktopLauncher.runningInstances()
        let previousByEmail = Dictionary(
            self.claudeDesktopAccounts.map { ($0.email, $0) },
            uniquingKeysWith: { first, _ in first })
        var values: [ClaudeAccountSnapshot] = []
        var profileByEmail: [String: ClaudeDesktopProfile] = [:]
        var desktopErrors: [String] = []

        for profile in profiles {
            let sessionKeys: [String]
            do {
                sessionKeys = try ClaudeDesktopSessionReader(dataDirectory: profile.dataDirectory).readSessionKeys()
            } catch ClaudeDesktopSessionError.cookieStoreMissing, ClaudeDesktopSessionError.noSessionKey {
                continue // Not signed in yet (for example, a profile whose sign-in is still in progress).
            } catch {
                desktopErrors.append("\(profile.name): \(error.localizedDescription)")
                continue
            }

            let knownEmail = self.claudeDesktopProfileByEmail.first { $0.value.name == profile.name }?.key
            self.refreshingClaudeDesktopEmail = knownEmail
            // Newest sign-in first; an older account's cookie can linger in the same profile.
            var sessionKey = sessionKeys[0]
            var fetchedEmail: String?
            for candidate in sessionKeys {
                if let email = try? await self.claudeWebAPI.fetchEmail(sessionKey: candidate) {
                    sessionKey = candidate
                    fetchedEmail = email
                    break
                }
            }
            let email = fetchedEmail ?? knownEmail ?? "Claude (\(profile.name))"
            guard profileByEmail[email] == nil else { continue } // Two profiles signed in to one account.

            var snapshot = ClaudeAccountSnapshot(
                email: email,
                isActive: ClaudeDesktopLauncher.instance(for: profile, in: instances) != nil,
                usage: previousByEmail[email]?.usage,
                usageError: nil,
                detail: "Profile: \(profile.name)")
            profileByEmail[email] = profile
            self.refreshingClaudeDesktopEmail = email

            do {
                snapshot.usage = try await self.claudeWebAPI.fetchUsage(sessionKey: sessionKey)
            } catch {
                snapshot.usageError = error.localizedDescription
            }
            values.append(snapshot)
        }

        // Keep existing cards visible until every desktop profile has been checked.
        self.claudeDesktopProfileByEmail = profileByEmail
        self.claudeDesktopAccounts = values
        self.claudeDesktopRecommendedEmail = values.isEmpty
            ? nil
            : ClaudeRecommendationEngine.recommendedEmail(accounts: values, now: Date())
        self.claudeDesktopError = desktopErrors.isEmpty ? nil : desktopErrors.joined(separator: "\n")
    }

    /// Creates a new empty Claude profile and opens it so the next account can be signed in.
    func addClaudeProfile() async {
        guard self.busyClaudeDesktopEmail == nil else { return }
        do {
            let profile = try self.claudeDesktopProfiles.createProfile(named: self.claudeDesktopProfiles.nextProfileName())
            try self.claudeDesktopLauncher.open(profile)
            self.statusMessage = "Opened a new Claude window. Sign in with the emailed code, then reopen this menu."
        } catch {
            self.errorMessage = error.localizedDescription
        }
    }

    func switchClaudeDesktopTo(email: String) async {
        guard self.busyClaudeDesktopEmail == nil else { return }
        guard let profile = self.claudeDesktopProfileByEmail[email] else {
            self.errorMessage = "No Claude profile was found for \(email)."
            return
        }
        self.busyClaudeDesktopEmail = email
        defer { self.busyClaudeDesktopEmail = nil }
        do {
            try self.claudeDesktopLauncher.open(profile)
            self.statusMessage = "Opened Claude as \(email)"
            try? await Task.sleep(for: .seconds(2))
            await self.refreshClaudeDesktopAccounts()
        } catch {
            self.errorMessage = error.localizedDescription
        }
    }

    func nextClaudeDesktop() async {
        guard !self.claudeDesktopAccounts.isEmpty else {
            self.errorMessage = "No Claude desktop accounts were found."
            return
        }
        let target: ClaudeAccountSnapshot
        if let activeIndex = self.claudeDesktopAccounts.firstIndex(where: \ .isActive) {
            target = self.claudeDesktopAccounts[(activeIndex + 1) % self.claudeDesktopAccounts.count]
        } else {
            target = self.claudeDesktopAccounts[0]
        }
        await self.switchClaudeDesktopTo(email: target.email)
    }

    func maxingClaudeDesktop() async {
        guard let email = self.claudeDesktopRecommendedEmail else {
            self.errorMessage = "No Claude desktop account has usable session quota data."
            return
        }
        await self.switchClaudeDesktopTo(email: email)
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

    var canRemoveClaudeDesktopAccount: Bool {
        self.claudeDesktopRefreshCount == 0 && self.busyClaudeDesktopEmail == nil
    }

    func removeClaudeAccount(email: String) {
        guard self.canRemoveClaudeAccount,
              let index = self.claudeAccounts.firstIndex(where: { $0.email == email }),
              self.claudeAccounts[index].isSaved
        else { return }
        do {
            try self.claudeAuthStore.removeSavedAccount(email: email)
            if self.claudeLiveDataByEmail[email] != nil {
                // Still signed in; only the saved copy is gone.
                self.claudeAccounts[index].isSaved = false
                self.claudeAccounts[index].detail = self.claudeAccounts[index].detail?
                    .replacingOccurrences(of: " · saved", with: "")
                return
            }
            self.claudeAccounts.removeAll { $0.email == email }
            self.claudeRecommendedEmail = ClaudeRecommendationEngine.recommendedEmail(
                accounts: self.claudeAccounts, now: Date())
        } catch {
            self.errorMessage = error.localizedDescription
        }
    }

    /// Hides the desktop profile from the list. The profile folder and its sign-in stay on disk.
    func removeClaudeDesktopAccount(email: String) {
        guard self.canRemoveClaudeDesktopAccount,
              self.claudeDesktopAccounts.contains(where: { $0.email == email }),
              let profile = self.claudeDesktopProfileByEmail[email]
        else { return }
        if !self.hiddenClaudeProfiles.contains(profile.name) {
            self.hiddenClaudeProfiles.append(profile.name)
            UserDefaults.standard.set(self.hiddenClaudeProfiles, forKey: Self.hiddenClaudeProfilesKey)
        }
        self.claudeDesktopProfileByEmail.removeValue(forKey: email)
        self.claudeDesktopAccounts.removeAll { $0.email == email }
        self.claudeDesktopRecommendedEmail = self.claudeDesktopAccounts.isEmpty
            ? nil
            : ClaudeRecommendationEngine.recommendedEmail(accounts: self.claudeDesktopAccounts, now: Date())
    }

    func restoreHiddenClaudeProfiles() async {
        guard self.canRemoveClaudeDesktopAccount else { return }
        self.hiddenClaudeProfiles = []
        UserDefaults.standard.removeObject(forKey: Self.hiddenClaudeProfilesKey)
        await self.refreshClaudeDesktopAccounts()
    }

    func saveCurrent() async {
        await self.perform {
            let email = try self.authStore.saveCurrent()
            self.statusMessage = "Saved \(email)"
            await self.refreshCodexAccounts()
        }
    }

    func switchTo(email: String) async {
        guard self.canRemoveCodexAccount else { return }
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
                try await CodexRestarter.restart(beforeLaunch: CodexRestarter.syncLocalProjects)
                self.statusMessage = "Loaded \(email) and restarted ChatGPT"
            }
            await self.refreshCodexAccounts()
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
                self.errorMessage = "Sign in to Claude Code first (no file-backed credential was found)."
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
            if let current = try self.claudeAuthStore.currentLogin() {
                guard let activeEmail = try await self.claudeAPI.fetchEmail(credentials: current.credentials),
                      !activeEmail.isEmpty
                else {
                    self.errorMessage = "Could not identify the current Claude Code account, so it was not replaced."
                    return
                }
                if activeEmail == email {
                    self.statusMessage = "\(email) is already active"
                    return
                }
                // Keep the outgoing login (with its latest refresh token) before replacing it.
                try self.claudeAuthStore.save(current.data, email: activeEmail)
            }
            guard let data = self.claudeAuthStore.savedData(email: email) ?? self.claudeLiveDataByEmail[email] else {
                throw ClaudeAuthStoreError.accountNotFound(email)
            }
            try self.claudeAuthStore.activate(data)
            self.statusMessage = "Loaded Claude Code account \(email). Restart running claude sessions to use it."
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

    func changeCodexProjects(email: String, backup: URL? = nil) async {
        guard self.canRemoveCodexAccount else { return }
        self.busyEmail = email
        defer { self.busyEmail = nil }
        let arguments = backup.map { ["_restore-projects-after-quit", email, $0.path] }
            ?? ["_delete-projects-after-quit", email]
        await self.perform {
            try await CodexRestarter.restart(beforeLaunch: {
                try await CodexRestarter.projectCommand(arguments)
            })
            self.statusMessage = backup == nil ? "Deleted local projects for \(email)" : "Restored local projects for \(email)"
        }
    }

    var projectBackupsDirectory: URL {
        self.authStore.savedDirectory.appendingPathComponent("project-backups", isDirectory: true)
    }

    func logout() async {
        guard self.canRemoveCodexAccount else { return }
        self.busyEmail = self.activeEmail ?? "ChatGPT"
        defer { self.busyEmail = nil }
        await self.perform {
            let email = try self.authStore.logout()
            try await CodexRestarter.restart()
            self.statusMessage = "Logged out \(email)"
            await self.refreshCodexAccounts()
        }
    }

    func restartCodex() async {
        guard self.canRemoveCodexAccount else { return }
        self.busyEmail = self.activeEmail ?? "ChatGPT"
        defer { self.busyEmail = nil }
        await self.perform {
            try await CodexRestarter.restart(beforeLaunch: CodexRestarter.syncLocalProjects)
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

            await self.refreshCodexAccounts()
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
