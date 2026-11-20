import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var stayAwake: StayAwakeController
    @EnvironmentObject private var lidAwake: LidAwakeController
    @AppStorage("restartAfterSwitch") private var restartAfterSwitch = true
    // Show/hide state for each provider section and each account card; persisted across panel opens and launches.
    /// Newline-separated "provider|email" keys of account cards whose usage details are hidden.
    @AppStorage("hiddenAccountCards") private var hiddenAccountCardsRaw = ""
    @AppStorage("sectionHidden.codex") private var codexHidden = false
    @AppStorage("sectionHidden.claudeCode") private var claudeCodeHidden = false
    @AppStorage("sectionHidden.claudeDesktop") private var claudeDesktopHidden = false
    @State private var confirmsLogout = false
    @State private var projectDeletionEmail: String?
    @State private var panelWindowNumber: Int?
    @FocusState private var timerInputFocused: Bool
    @State private var listContentHeight: CGFloat = 0
    /// Keeps the whole panel at most about 700 points tall; shorter lists shrink the panel instead of
    /// leaving empty space below the last section.
    private static let maxListHeight: CGFloat = 560

    var body: some View {
        VStack(spacing: 0) {
            self.header
            Divider()
            self.stayAwakeSection
            Divider()
            TimerCard(inputFocus: self.$timerInputFocused)
            Divider()
            self.accountList
        }
        .frame(width: 430)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            if let message = self.model.statusMessage {
                Text(message)
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(radius: 5, y: 2)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .onAppear {
            Task { await self.lidAwake.refresh() }
            Task {
                await self.model.refreshOnOpen()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) {
            self.refreshWhenPanelOpens(notification: $0)
        }
        .onChange(of: self.model.statusMessage) { message in
            guard let message else { return }
            Task {
                try? await Task.sleep(for: .seconds(4))
                guard self.model.statusMessage == message else { return }
                self.model.statusMessage = nil
            }
        }
        .alert("Log out of Codex?", isPresented: self.$confirmsLogout) {
            Button("Cancel", role: .cancel) {}
            Button("Log Out", role: .destructive) {
                Task { await self.model.logout() }
            }
        } message: {
            Text("The active account will be saved, auth.json will be removed, and ChatGPT will restart.")
        }
        .alert("Delete local projects?", isPresented: Binding(
            get: { self.projectDeletionEmail != nil },
            set: { if !$0 { self.projectDeletionEmail = nil } }))
        {
            Button("Cancel", role: .cancel) {}
            Button("Delete Projects", role: .destructive) {
                if let email = self.projectDeletionEmail {
                    Task { await self.model.changeCodexProjects(email: email) }
                }
            }
        } message: {
            Text("Remove all local project entries for \(self.projectDeletionEmail ?? "this account")? A backup is saved first. Project folders and chats stay on disk.")
        }
        .alert("Go Codex Bar", isPresented: Binding(
            get: { self.model.errorMessage != nil },
            set: { if !$0 { self.model.errorMessage = nil } }))
        {
            Button("OK", role: .cancel) { self.model.errorMessage = nil }
        } message: {
            Text(self.model.errorMessage ?? "Unknown error")
        }
    }

    private func chooseProjectBackup(email: String) {
        let panel = NSOpenPanel()
        panel.title = "Restore Projects for \(email)"
        panel.message = "Choose a backup for this account. Its current projects will be backed up before restoring."
        panel.directoryURL = self.model.projectBackupsDirectory
        panel.allowedContentTypes = [.json]
        panel.prompt = "Restore"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { await self.model.changeCodexProjects(email: email, backup: url) }
        }
    }

    private func refreshWhenPanelOpens(notification: Notification) {
        guard let window = notification.object as? NSWindow, window.isVisible else { return }

        if self.panelWindowNumber == nil {
            self.panelWindowNumber = window.windowNumber
        }
        guard self.panelWindowNumber == window.windowNumber else { return }

        self.timerInputFocused = false
        Task { await self.lidAwake.refresh() }
        Task {
            await self.model.refreshOnOpen()
        }
    }

    private var stayAwakeSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label("Stay Awake", systemImage: self.stayAwake.isEnabled ? "sun.max.fill" : "sun.max")
                Spacer()
                Toggle("Stay Awake", isOn: Binding(
                    get: { self.stayAwake.isEnabled },
                    set: { self.stayAwake.setEnabled($0) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .help("Keep the screen on and prevent idle sleep while Go Codex Bar is running.")
                Divider().frame(height: 18).padding(.horizontal, 6)
                Label("Lid Awake", systemImage: "laptopcomputer")
                Spacer()
                if self.lidAwake.isBusy {
                    ProgressView().controlSize(.mini)
                }
                Toggle("Lid Awake", isOn: Binding(
                    get: { self.lidAwake.isEnabled == true },
                    set: { enabled in Task { await self.lidAwake.setEnabled(enabled) } }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .disabled(self.lidAwake.isBusy || self.lidAwake.isEnabled == nil)
                    .help("Keep running with the lid closed. Requires administrator approval. Disables system sleep until turned off, even after quitting this app.")
            }
            .font(.caption)
            .controlSize(.small)
            if self.lidAwake.isEnabled == true {
                Text("Lid Awake: system sleep disabled until turned off, even after quitting.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            if let error = self.stayAwake.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if let error = self.lidAwake.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                Button("Retry sleep status") {
                    Task { await self.lidAwake.refresh() }
                }
                .font(.caption)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var header: some View {
        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(LinearGradient(
                        colors: [.indigo, .cyan],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing))
                Image(systemName: "bolt.horizontal.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 28, height: 28)

            Text("Go Codex Bar")
                .font(.headline)
                .lineLimit(1)
            Spacer()

            Button {
                Task { await self.model.refresh() }
            } label: {
                if self.model.isRefreshing {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(.borderless)
            .disabled(self.model.isRefreshing || self.model.isRefreshingExpired)
            .help("Refresh usage")

            Menu {
                Toggle("Restart after switching", isOn: self.$restartAfterSwitch)
                Divider()
                Button("Quit Go Codex Bar", systemImage: "power", role: .destructive) {
                    NSApplication.shared.terminate(nil)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var resetStatusSection: some View {
        if let status = self.model.codexResetStatus {
            ResetStatusCard(status: status)
        } else if let error = self.model.codexResetStatusError {
            ResetStatusErrorCard(message: error.message, responseCode: error.responseCode) {
                self.model.dismissCodexResetStatusError()
            }
        }
    }

    private var accountList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // A plain VStack: LazyVStack mis-estimates the height of cards whose usage loads later,
                // which left blank space at the bottom of the list.
                VStack(alignment: .leading, spacing: 12) {
                    Section {
                        if !self.codexHidden {
                            self.resetStatusSection
                            ForEach(self.sortedAccounts) { account in
                                AccountCard(
                                    email: account.email,
                                    isActive: account.isActive,
                                    isRecommended: account.email == self.model.recommendedEmail,
                                    isBusy: account.email == self.model.busyEmail,
                                    isRefreshing: account.email == self.model.refreshingEmail,
                                    usageError: account.usageError,
                                    session: account.primaryWindow.flatMap {
                                        UsageLine(title: "Session", remaining: $0.remainingPercent, resetDate: $0.resetDate)
                                    },
                                    weekly: account.secondaryWindow.flatMap {
                                        UsageLine(title: "Weekly", remaining: $0.remainingPercent, resetDate: $0.resetDate)
                                    },
                                    credits: account.availableResetCredits(at: Date()).map(\.expiresAt),
                                    isCollapsed: self.isCardHidden("codex", account.email),
                                    toggleCollapsed: { self.toggleCardHidden("codex", account.email) })
                                {
                                    Task { await self.model.switchTo(email: account.email) }
                                }
                                .contextMenu {
                                    Button("Restore Projects…", systemImage: "arrow.counterclockwise") {
                                        self.chooseProjectBackup(email: account.email)
                                    }
                                    .disabled(!self.model.canRemoveCodexAccount)
                                    Button("Delete Projects…", systemImage: "folder.badge.minus", role: .destructive) {
                                        self.projectDeletionEmail = account.email
                                    }
                                    .disabled(!self.model.canRemoveCodexAccount)
                                    Divider()
                                    Button("Remove Saved Account", systemImage: "trash", role: .destructive) {
                                        self.model.removeCodexAccount(email: account.email)
                                    }
                                    .disabled(!self.model.canRemoveCodexAccount)
                                }
                            }
                        }
                    } header: {
                        self.accountSectionHeader(
                            "Codex", count: self.model.accounts.count, isHidden: self.$codexHidden)
                        {
                            Button("Save Current", systemImage: "square.and.arrow.down") {
                                Task { await self.model.saveCurrent() }
                            }
                            Button("Refresh Expired", systemImage: "key.horizontal") {
                                Task { await self.model.refreshExpired() }
                            }
                            .disabled(self.model.accounts.isEmpty || !self.model.canRemoveCodexAccount)
                            Button("Open Saved Accounts", systemImage: "folder") {
                                self.model.openSavedAccountsFolder()
                            }
                            Divider()
                            Button("Restart ChatGPT", systemImage: "arrow.clockwise.circle") {
                                Task { await self.model.restartCodex() }
                            }
                            Button("Log Out", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                                self.confirmsLogout = true
                            }
                        }
                    }
                    Section {
                        if !self.claudeCodeHidden {
                            if self.model.claudeAccounts.isEmpty && self.model.claudeRefreshCount == 0 {
                                Text("No Claude Code login found. Run `claude` and sign in, then refresh.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            ForEach(self.sortedClaudeAccounts) { account in
                                AccountCard(
                                    email: account.email,
                                    isActive: account.isActive,
                                    isRecommended: account.email == self.model.claudeRecommendedEmail,
                                    isBusy: account.email == self.model.busyClaudeEmail,
                                    isRefreshing: account.email == self.model.refreshingClaudeEmail,
                                    usageError: account.usageError,
                                    session: (account.usage?.fiveHour).flatMap {
                                        UsageLine(title: "Session", remaining: $0.remainingPercent, resetDate: $0.resetDate)
                                    },
                                    weekly: (account.usage?.sevenDay).flatMap {
                                        UsageLine(title: "Weekly", remaining: $0.remainingPercent, resetDate: $0.resetDate)
                                    },
                                    credits: (account.usage?.availableResetExpirations(at: Date())).flatMap {
                                        $0.isEmpty ? nil : $0
                                    },
                                    detail: account.detail,
                                    isCollapsed: self.isCardHidden("claudeCode", account.email),
                                    toggleCollapsed: { self.toggleCardHidden("claudeCode", account.email) })
                                {
                                    Task { await self.model.switchClaudeTo(email: account.email) }
                                }
                                .contextMenu {
                                    Button("Remove Saved Account", systemImage: "trash", role: .destructive) {
                                        self.model.removeClaudeAccount(email: account.email)
                                    }
                                    .disabled(!self.model.canRemoveClaudeAccount || !account.isSaved)
                                }
                            }
                        }
                    } header: {
                        self.accountSectionHeader(
                            "Claude Code", count: self.model.claudeAccounts.count, isHidden: self.$claudeCodeHidden)
                        {
                            Button("Save Current Claude Code", systemImage: "square.and.arrow.down") {
                                Task { await self.model.saveCurrentClaude() }
                            }
                            Button("Next Claude Code", systemImage: "arrow.right.circle") {
                                Task { await self.model.nextClaude() }
                            }
                            .disabled(self.model.claudeAccounts.count < 2)
                            Button("Maxing Claude Code", systemImage: "gauge.with.dots.needle.67percent") {
                                Task { await self.model.maxingClaude() }
                            }
                            .disabled(self.model.claudeRecommendedEmail == nil)
                        }
                    }
                    Section {
                        if !self.claudeDesktopHidden {
                            if let error = self.model.claudeDesktopError {
                                Label(error, systemImage: "exclamationmark.triangle")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                                    .lineLimit(4)
                            }
                            ForEach(self.sortedClaudeDesktopAccounts) { account in
                                AccountCard(
                                    email: account.email,
                                    isActive: account.isActive,
                                    isRecommended: account.email == self.model.claudeDesktopRecommendedEmail,
                                    isBusy: account.email == self.model.busyClaudeDesktopEmail,
                                    isRefreshing: account.email == self.model.refreshingClaudeDesktopEmail,
                                    usageError: account.usageError,
                                    session: (account.usage?.fiveHour).flatMap {
                                        UsageLine(title: "Session", remaining: $0.remainingPercent, resetDate: $0.resetDate)
                                    },
                                    weekly: (account.usage?.sevenDay).flatMap {
                                        UsageLine(title: "Weekly", remaining: $0.remainingPercent, resetDate: $0.resetDate)
                                    },
                                    credits: (account.usage?.availableResetExpirations(at: Date())).flatMap {
                                        $0.isEmpty ? nil : $0
                                    },
                                    detail: account.detail,
                                    isCollapsed: self.isCardHidden("claudeDesktop", account.email),
                                    toggleCollapsed: { self.toggleCardHidden("claudeDesktop", account.email) })
                                {
                                    Task { await self.model.switchClaudeDesktopTo(email: account.email) }
                                }
                                .contextMenu {
                                    Button("Remove from List", systemImage: "trash", role: .destructive) {
                                        self.model.removeClaudeDesktopAccount(email: account.email)
                                    }
                                    .disabled(!self.model.canRemoveClaudeDesktopAccount)
                                }
                            }
                        }
                    } header: {
                        self.accountSectionHeader(
                            "Claude Desktop", count: self.model.claudeDesktopAccounts.count,
                            isHidden: self.$claudeDesktopHidden)
                        {
                            Button("Add Claude Profile", systemImage: "person.badge.plus") {
                                Task { await self.model.addClaudeProfile() }
                            }
                            .disabled(self.model.busyClaudeDesktopEmail != nil)
                            Button("Next Claude Desktop", systemImage: "arrow.right.circle") {
                                Task { await self.model.nextClaudeDesktop() }
                            }
                            .disabled(self.model.claudeDesktopAccounts.isEmpty)
                            Button("Maxing Claude Desktop", systemImage: "gauge.with.dots.needle.67percent") {
                                Task { await self.model.maxingClaudeDesktop() }
                            }
                            .disabled(self.model.claudeDesktopRecommendedEmail == nil)
                            if !self.model.hiddenClaudeProfiles.isEmpty {
                                Button("Restore Hidden Desktop Profiles", systemImage: "eye") {
                                    Task { await self.model.restoreHiddenClaudeProfiles() }
                                }
                                .disabled(!self.model.canRemoveClaudeDesktopAccount)
                            }
                        }
                    }
                    if self.model.accounts.isEmpty && self.model.claudeAccounts.isEmpty
                        && self.model.claudeDesktopAccounts.isEmpty
                    {
                        Text("No saved accounts")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 20)
                    }
                }
                .padding(12)
                .background(GeometryReader { geometry in
                    Color.clear.preference(key: ListContentHeightKey.self, value: geometry.size.height)
                })
            }
            .onPreferenceChange(ListContentHeightKey.self) { height in
                self.listContentHeight = height
            }
            .onChange(of: self.model.activeEmail) { activeEmail in
                guard let activeEmail else { return }
                withAnimation {
                    proxy.scrollTo(activeEmail, anchor: .top)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: min(max(self.listContentHeight, 80), Self.maxListHeight))
    }

    private func accountSectionHeader<Actions: View>(
        _ title: String, count: Int, isHidden: Binding<Bool>, @ViewBuilder actions: () -> Actions
    ) -> some View {
        HStack {
            Text(title).font(.headline)
            if isHidden.wrappedValue {
                Text("\(count) hidden")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Menu(content: actions) {
                Image(systemName: "ellipsis.circle")
                    .accessibilityLabel("\(title) account actions")
            }
            .menuStyle(.borderlessButton)
            .controlSize(.small)
            .fixedSize()
            Button {
                isHidden.wrappedValue.toggle()
            } label: {
                Image(systemName: isHidden.wrappedValue ? "eye.slash" : "eye")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help(isHidden.wrappedValue ? "Show \(title)" : "Hide \(title)")
            .accessibilityLabel(isHidden.wrappedValue ? "Show \(title)" : "Hide \(title)")
        }
    }

    private var hiddenAccountCards: Set<String> {
        Set(self.hiddenAccountCardsRaw.split(separator: "\n").map(String.init))
    }

    private func isCardHidden(_ provider: String, _ email: String) -> Bool {
        self.hiddenAccountCards.contains("\(provider)|\(email)")
    }

    private func toggleCardHidden(_ provider: String, _ email: String) {
        var keys = self.hiddenAccountCards
        let key = "\(provider)|\(email)"
        if keys.contains(key) {
            keys.remove(key)
        } else {
            keys.insert(key)
        }
        self.hiddenAccountCardsRaw = keys.sorted().joined(separator: "\n")
    }

    private var sortedAccounts: [AccountSnapshot] {
        self.model.accounts.filter(\.isActive)
            + self.model.accounts.filter { !$0.isActive }
    }

    private var sortedClaudeDesktopAccounts: [ClaudeAccountSnapshot] {
        self.model.claudeDesktopAccounts.filter(\.isActive)
            + self.model.claudeDesktopAccounts.filter { !$0.isActive }
    }

    private var sortedClaudeAccounts: [ClaudeAccountSnapshot] {
        self.model.claudeAccounts.filter(\.isActive)
            + self.model.claudeAccounts.filter { !$0.isActive }
    }
}

private struct TimerCard: View {
    let inputFocus: FocusState<Bool>.Binding
    @State private var input = "00:00:00"
    @State private var configuredSeconds = 0
    @State private var remainingSeconds = 0
    @State private var isRunning = false
    @State private var alarmSound: NSSound?
    @State private var alarmGeneration = 0

    var body: some View {
        HStack(spacing: 10) {
            Label("Timer", systemImage: "timer")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.orange)
            TextField("00:00:00", text: self.$input)
                .focused(self.inputFocus)
                .textFieldStyle(.roundedBorder)
                .font(.body.monospacedDigit())
                .frame(width: 88)
                .disabled(self.isRunning)
                .onSubmit(self.play)
            Text(self.countdownText)
                .font(.system(.body, design: .monospaced, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(self.isRunning ? .orange : .secondary)
            Spacer()
            Button(action: self.play) {
                Image(systemName: "play.fill")
            }
            .disabled(self.isRunning || (self.remainingSeconds == 0 && self.parsedInput == nil))
            .help("Play")
            Button(action: { self.isRunning = false }) {
                Image(systemName: "pause.fill")
            }
            .disabled(!self.isRunning)
            .help("Pause")
            Button(action: self.reset) {
                Image(systemName: "arrow.counterclockwise")
            }
            .disabled(self.parsedInput == nil && self.configuredSeconds == 0 && self.remainingSeconds == 0)
            .help("Reset")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            guard self.isRunning else { return }
            if self.remainingSeconds > 1 {
                self.remainingSeconds -= 1
            } else {
                self.remainingSeconds = 0
                self.isRunning = false
                self.alarmGeneration += 1
                let generation = self.alarmGeneration
                for second in 0..<3 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(second)) {
                        guard generation == self.alarmGeneration else { return }
                        self.playAlarm()
                    }
                }
            }
        }
    }

    private var parsedInput: Int? {
        let parts = self.input.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let hours = Int(parts[0]),
              let minutes = Int(parts[1]),
              let seconds = Int(parts[2]),
              hours >= 0,
              (0..<60).contains(minutes),
              (0..<60).contains(seconds)
        else {
            return nil
        }
        return hours * 3_600 + minutes * 60 + seconds
    }

    private var countdownText: String {
        Self.timeString(self.remainingSeconds)
    }

    private func play() {
        if self.remainingSeconds == 0 {
            guard self.setDurationFromInput(), self.remainingSeconds > 0 else { return }
            self.stopAlarm()
        }
        self.isRunning = true
    }

    private func reset() {
        guard self.setDurationFromInput() else { return }
        self.isRunning = false
        self.stopAlarm()
    }

    @discardableResult
    private func setDurationFromInput() -> Bool {
        guard let seconds = self.parsedInput else { return false }
        self.input = Self.timeString(seconds)
        self.configuredSeconds = seconds
        self.remainingSeconds = seconds
        return true
    }

    private static func timeString(_ totalSeconds: Int) -> String {
        String(format: "%02d:%02d:%02d", totalSeconds / 3_600, (totalSeconds % 3_600) / 60, totalSeconds % 60)
    }

    private func playAlarm() {
        if self.alarmSound == nil,
           let url = Bundle.main.url(forResource: "alarm", withExtension: "wav")
        {
            self.alarmSound = NSSound(contentsOf: url, byReference: true)
        }
        guard let alarmSound else {
            NSSound.beep()
            return
        }
        alarmSound.stop()
        alarmSound.play()
    }

    private func stopAlarm() {
        self.alarmGeneration += 1
        self.alarmSound?.stop()
    }
}

private struct ResetStatusCard: View {
    let status: CodexResetsResponse

    var body: some View {
        let upcoming = (self.status.scheduled?.scheduledFor).flatMap { $0 > Date() ? $0 : nil }
        if let date = upcoming ?? self.status.stats.lastResetAt {
            HStack(spacing: 6) {
                Text(upcoming != nil ? "Upcoming reset" : "Last reset")
                Spacer(minLength: 8)
                Text(Self.localTimestamp.string(from: date))
                    .monospacedDigit()
                Text("(\(date.formatted(.relative(presentation: .numeric))))")
                    .foregroundStyle(.secondary)
                if let announcementURL = self.status.scheduled?.tweetURL {
                    Link(destination: announcementURL) {
                        Image(systemName: "arrow.up.right")
                    }
                    .help("View reset announcement")
                    .accessibilityLabel("View reset announcement")
                }
            }
            .font(.caption)
            .lineLimit(1)
        }
    }

    private static let localTimestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.timeZone = .current
        formatter.dateFormat = "MMM d, HH:mm zzz"
        return formatter
    }()
}

private struct ResetStatusErrorCard: View {
    let message: String
    let responseCode: Int?
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("codex-resets unavailable")
                        .font(.subheadline.weight(.semibold))
                    if let responseCode {
                        Text("HTTP \(responseCode)")
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                Text(self.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Link("Open site ↗", destination: URL(string: "https://codex-resets.com/")!)
                .font(.caption.weight(.semibold))
            Button(action: self.dismiss) {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.borderless)
            .help("Dismiss")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.orange.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.orange.opacity(0.35), lineWidth: 1))
    }
}

private struct AccountCard: View {
    let email: String
    let isActive: Bool
    let isRecommended: Bool
    let isBusy: Bool
    let isRefreshing: Bool
    let usageError: String?
    let session: UsageLine?
    let weekly: UsageLine?
    /// Expiry of each saved reset (`nil` = never expires). `nil` hides the row.
    let credits: [Date?]?
    /// Small secondary line under the email, such as the desktop profile name.
    var detail: String? = nil
    /// When true only the email row is shown; usage, errors and credits are hidden.
    var isCollapsed = false
    var toggleCollapsed: () -> Void = {}
    let action: () -> Void

    var body: some View {
        Button(action: self.action) {
            Group {
                if self.isCollapsed {
                    self.compactRow
                } else {
                    VStack(alignment: .leading, spacing: 9) {
                        HStack(spacing: 7) {
                            Circle()
                                .fill(self.isActive ? Color.green : Color.secondary.opacity(0.35))
                                .frame(width: 7, height: 7)
                            Text(self.email)
                                .font(.system(.subheadline, design: .rounded, weight: .semibold))
                                .lineLimit(1)
                            Spacer()
                            if self.isRefreshing {
                                RefreshingBadge(color: .indigo)
                            } else {
                                if self.isActive {
                                    Badge(text: "ACTIVE", color: .green)
                                }
                                if self.isRecommended {
                                    Badge(text: "RECOMMENDED", color: .indigo)
                                }
                            }
                            if self.isBusy {
                                ProgressView().controlSize(.mini)
                            }
                            // Reserves room for the show/hide button overlaid outside the card's button.
                            Color.clear.frame(width: 16, height: 1)
                        }
                        if let detail = self.detail {
                            Text(detail)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .padding(.leading, 14)
                                .padding(.top, -5)
                        }

                        if let error = self.usageError {
                            Label(error, systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .lineLimit(2)
                        } else if self.session != nil || self.weekly != nil {
                            HStack(spacing: 10) {
                                self.session
                                if self.session != nil && self.weekly != nil {
                                    Divider()
                                }
                                self.weekly
                            }
                            .fixedSize(horizontal: false, vertical: true)
                        } else {
                            Text("Usage unavailable")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if let credits = self.credits {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Image(systemName: "arrow.counterclockwise.circle.fill")
                                    .foregroundStyle(.cyan)
                                Text("\(credits.count) reset credit\(credits.count == 1 ? "" : "s")")
                                    .font(.caption.weight(.medium))
                                if !credits.isEmpty {
                                    Text(credits.map(Self.expiryLabel).joined(separator: " · "))
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, self.isCollapsed ? 7 : 11)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(self.isActive ? Color.accentColor.opacity(0.09) : Color.primary.opacity(0.045)))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(self.isRecommended ? Color.indigo.opacity(0.45) : Color.clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(self.isActive || self.isBusy)
        // Kept outside the card's button so it still works on the active (disabled) card.
        .overlay(alignment: self.isCollapsed ? .trailing : .topTrailing) {
            Button(action: self.toggleCollapsed) {
                Image(systemName: self.isCollapsed ? "eye.slash" : "eye")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help(self.isCollapsed ? "Show usage" : "Hide usage")
            .accessibilityLabel(self.isCollapsed ? "Show usage for \(self.email)" : "Hide usage for \(self.email)")
            .padding(.top, self.isCollapsed ? 0 : 11)
            .padding(.trailing, 11)
        }
    }

    /// Hidden-card layout: short name plus a ring per quota window; no badges or spinners.
    private var compactRow: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(self.isActive ? Color.green : Color.secondary.opacity(0.35))
                .frame(width: 7, height: 7)
            Text(Self.shortName(self.email))
                .font(.system(.subheadline, design: .rounded, weight: .semibold))
                .lineLimit(1)
                .help(self.email)
            Spacer(minLength: 6)
            if let error = self.usageError {
                Image(systemName: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .help(error)
            } else {
                if let session = self.session { UsageRing(line: session) }
                if let weekly = self.weekly { UsageRing(line: weekly) }
            }
            // Reserves room for the show/hide button overlaid outside the card's button.
            Color.clear.frame(width: 16, height: 1)
        }
    }

    /// "name@gmail.com" -> "name".
    private static func shortName(_ email: String) -> String {
        guard let at = email.firstIndex(of: "@"), at != email.startIndex else { return email }
        return String(email[..<at])
    }

    private static func expiryLabel(_ expiry: Date?) -> String {
        guard let expiry else { return "No expiry" }
        return expiry.formatted(.dateTime.month(.abbreviated).day())
    }
}

private struct UsageLine: View {
    let title: String
    let remaining: Double
    let resetDate: Date?

    init?(title: String, remaining: Double?, resetDate: Date?) {
        guard let remaining else { return nil }
        self.title = title
        self.remaining = remaining
        self.resetDate = resetDate
    }

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text(self.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(self.remaining, specifier: "%.0f")% left")
                    .font(.caption.monospacedDigit().weight(.semibold))
                if let reset = self.resetDate, reset > Date() {
                    Text("· \(reset, style: .relative)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.09))
                    Capsule()
                        .fill(self.barColor)
                        .frame(width: geometry.size.width * self.remaining / 100)
                        .animation(.easeOut(duration: 0.6), value: self.remaining)
                }
            }
            .frame(height: 5)
        }
    }

    var barColor: Color {
        switch self.remaining {
        case 50...: .green
        case 20...: .orange
        default: .red
        }
    }
}

/// Small circular quota gauge: remaining percent in the center, window title below.
private struct UsageRing: View {
    let line: UsageLine

    var body: some View {
        VStack(spacing: 2) {
            ZStack {
                Circle()
                    .stroke(Color.primary.opacity(0.1), lineWidth: 3)
                Circle()
                    .trim(from: 0, to: max(0, min(1, self.line.remaining / 100)))
                    .stroke(self.line.barColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.6), value: self.line.remaining)
                Text("\(self.line.remaining, specifier: "%.0f")")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .monospacedDigit()
            }
            .frame(width: 26, height: 26)
            Text(self.line.title)
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .help(self.ringHelp)
    }

    private var ringHelp: String {
        var text = "\(self.line.title): \(Int(self.line.remaining.rounded()))% left"
        if let reset = self.line.resetDate, reset > Date() {
            text += ", resets \(reset.formatted(.relative(presentation: .named)))"
        }
        return text
    }
}

private struct Badge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(self.text)
            .font(.system(size: 8, weight: .bold, design: .rounded))
            .foregroundStyle(self.color)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Capsule().fill(self.color.opacity(0.13)))
    }
}

private struct RefreshingBadge: View {
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            ProgressView()
                .controlSize(.mini)
            Text("UPDATING")
        }
        .font(.system(size: 8, weight: .bold, design: .rounded))
        .foregroundStyle(self.color)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(Capsule().fill(self.color.opacity(0.13)))
    }
}

private struct ListContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
