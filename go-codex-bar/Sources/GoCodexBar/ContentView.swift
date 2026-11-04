import AppKit
import Combine
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var stayAwake: StayAwakeController
    @EnvironmentObject private var lidAwake: LidAwakeController
    @AppStorage("restartAfterSwitch") private var restartAfterSwitch = true
    @State private var confirmsLogout = false
    @State private var panelWindowNumber: Int?
    @FocusState private var timerInputFocused: Bool

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
        .frame(width: 430, height: 700)
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
        .alert("Go Codex Bar", isPresented: Binding(
            get: { self.model.errorMessage != nil },
            set: { if !$0 { self.model.errorMessage = nil } }))
        {
            Button("OK", role: .cancel) { self.model.errorMessage = nil }
        } message: {
            Text(self.model.errorMessage ?? "Unknown error")
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
                LazyVStack(alignment: .leading, spacing: 12) {
                    Section {
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
                                credits: account.availableResetCredits(at: Date()))
                            {
                                Task { await self.model.switchTo(email: account.email) }
                            }
                            .contextMenu {
                                Button("Remove Saved Account", systemImage: "trash", role: .destructive) {
                                    self.model.removeCodexAccount(email: account.email)
                                }
                                .disabled(!self.model.canRemoveCodexAccount)
                            }
                        }
                    } header: {
                        self.accountSectionHeader("Codex") {
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
                                credits: nil)
                            {
                                Task { await self.model.switchClaudeTo(email: account.email) }
                            }
                            .contextMenu {
                                Button(self.model.isClaudeDesktopSession ? "Remove from List" : "Remove Saved Account", systemImage: "trash", role: .destructive) {
                                    self.model.removeClaudeAccount(email: account.email)
                                }
                                .disabled(!self.model.canRemoveClaudeAccount)
                            }
                        }
                    } header: {
                        self.accountSectionHeader("Claude") {
                            Button("Save Current Claude", systemImage: "square.and.arrow.down") {
                                Task { await self.model.saveCurrentClaude() }
                            }
                            Button("Add Claude Profile", systemImage: "person.badge.plus") {
                                Task { await self.model.addClaudeProfile() }
                            }
                            .disabled(self.model.busyClaudeEmail != nil)
                            if !self.model.hiddenClaudeProfiles.isEmpty {
                                Button("Restore Hidden Desktop Profiles", systemImage: "eye") {
                                    Task { await self.model.restoreHiddenClaudeProfiles() }
                                }
                                .disabled(!self.model.canRemoveClaudeAccount)
                            }
                        }
                    }
                    if self.model.accounts.isEmpty && self.model.claudeAccounts.isEmpty {
                        Text("No saved accounts")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 20)
                    }
                }
                .padding(12)
            }
            .onChange(of: self.model.activeEmail) { activeEmail in
                guard let activeEmail else { return }
                withAnimation {
                    proxy.scrollTo(activeEmail, anchor: .top)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func accountSectionHeader<Actions: View>(
        _ title: String, @ViewBuilder actions: () -> Actions
    ) -> some View {
        HStack {
            Text(title).font(.headline)
            Spacer()
            Menu(content: actions) {
                Image(systemName: "ellipsis.circle")
                    .accessibilityLabel("\(title) account actions")
            }
            .menuStyle(.borderlessButton)
            .controlSize(.small)
            .fixedSize()
        }
    }

    private var sortedAccounts: [AccountSnapshot] {
        self.model.accounts.filter(\.isActive)
            + self.model.accounts.filter { !$0.isActive }
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
    let credits: [ResetCredit]?
    let action: () -> Void

    var body: some View {
        Button(action: self.action) {
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
            .padding(11)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(self.isActive ? Color.accentColor.opacity(0.09) : Color.primary.opacity(0.045)))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(self.isRecommended ? Color.indigo.opacity(0.45) : Color.clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(self.isActive || self.isBusy)
    }

    private static func expiryLabel(_ credit: ResetCredit) -> String {
        guard let expiry = credit.expiresAt else { return "No expiry" }
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

    private var barColor: Color {
        switch self.remaining {
        case 50...: .green
        case 20...: .orange
        default: .red
        }
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
