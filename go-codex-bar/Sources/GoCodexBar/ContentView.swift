import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("restartAfterSwitch") private var restartAfterSwitch = true
    @State private var confirmsLogout = false
    @State private var panelWindowNumber: Int?

    var body: some View {
        VStack(spacing: 0) {
            self.header
            if self.model.codexResetStatus != nil || self.model.codexResetStatusError != nil {
                Divider()
                self.resetStatusSection
            }
            Divider()
            self.accountList
        }
        .frame(width: 430, height: 660)
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
            Text("The active account will be saved, auth.json will be removed, and Codex will restart.")
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

        Task {
            await self.model.refreshOnOpen()
        }
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
                Task { await self.model.next() }
            } label: {
                Label("Next", systemImage: "arrow.right.circle")
            }
            .disabled(
                self.model.accounts.isEmpty
                    || self.model.busyEmail != nil
                    || self.model.isRefreshing
                    || self.model.isRefreshingExpired)

            Button {
                Task { await self.model.maxing() }
            } label: {
                Label("Maxing", systemImage: "sparkles")
            }
            .buttonStyle(.borderedProminent)
            .disabled(
                self.model.recommendedEmail == nil
                    || self.model.busyEmail != nil
                    || self.model.isRefreshing
                    || self.model.isRefreshingExpired)

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
                Button("Save Current", systemImage: "square.and.arrow.down") {
                    Task { await self.model.saveCurrent() }
                }
                Button("Save Current Claude", systemImage: "sparkles") {
                    Task { await self.model.saveCurrentClaude() }
                }
                Button("Next Claude", systemImage: "arrow.right.circle") {
                    Task { await self.model.nextClaude() }
                }
                .disabled(self.model.claudeAccounts.isEmpty || self.model.busyClaudeEmail != nil)
                Button("Maxing Claude", systemImage: "sparkles") {
                    Task { await self.model.maxingClaude() }
                }
                .disabled(self.model.claudeRecommendedEmail == nil || self.model.busyClaudeEmail != nil)
                Divider()
                Button("Refresh Expired", systemImage: "key.horizontal") {
                    Task { await self.model.refreshExpired() }
                }
                .disabled(
                    self.model.accounts.isEmpty
                        || self.model.isRefreshing
                        || self.model.isRefreshingExpired
                        || self.model.busyEmail != nil)
                Button("Restart Codex", systemImage: "arrow.clockwise.circle") {
                    Task { await self.model.restartCodex() }
                }
                Button("Open Saved Accounts", systemImage: "folder") {
                    self.model.openSavedAccountsFolder()
                }
                Divider()
                Toggle("Restart after switching", isOn: self.$restartAfterSwitch)
                Divider()
                Button("Log Out", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                    self.confirmsLogout = true
                }
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
                .padding(10)
        } else if let error = self.model.codexResetStatusError {
            ResetStatusErrorCard(message: error.message, responseCode: error.responseCode) {
                self.model.dismissCodexResetStatusError()
            }
                .padding(10)
        }
    }

    @ViewBuilder
    private var accountList: some View {
        if self.model.accounts.isEmpty && self.model.claudeAccounts.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "person.crop.circle.badge.plus")
                    .font(.system(size: 32))
                    .foregroundStyle(.secondary)
                Text("No saved accounts")
                    .font(.headline)
                Text("Sign in with Codex or Claude Code, then save the current account.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Save Current") {
                    Task { await self.model.saveCurrent() }
                }
                .buttonStyle(.borderedProminent)
                Button("Save Current Claude") {
                    Task { await self.model.saveCurrentClaude() }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(30)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(self.sortedClaudeAccounts) { account in
                            ClaudeCard(
                                account: account,
                                isRecommended: account.email == self.model.claudeRecommendedEmail,
                                isBusy: account.email == self.model.busyClaudeEmail,
                                isRefreshing: account.email == self.model.refreshingClaudeEmail)
                            {
                                Task { await self.model.switchClaudeTo(email: account.email) }
                            }
                        }
                        ForEach(self.sortedAccounts) { account in
                            AccountCard(
                                account: account,
                                isRecommended: account.email == self.model.recommendedEmail,
                                isBusy: account.email == self.model.busyEmail,
                                isRefreshing: account.email == self.model.refreshingEmail)
                            {
                                Task { await self.model.switchTo(email: account.email) }
                            }
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

private struct ResetStatusCard: View {
    let status: CodexResetsResponse

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center) {
                Label("codex-resets", systemImage: "arrow.counterclockwise.circle")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.orange)
                Spacer()
                if let announcementURL = self.status.scheduled?.tweetURL {
                    Link("View announcement ↗", destination: announcementURL)
                        .font(.caption.monospaced())
                        .foregroundStyle(.orange.opacity(0.9))
                }
            }

            if let scheduledFor = self.status.scheduled?.scheduledFor,
               scheduledFor > Date()
            {
                ResetStatusRow(
                    title: "Next reset",
                    timestamp: Self.localTimestamp.string(from: scheduledFor),
                    detail: self.relativeSchedule(scheduledFor))
            }
            if let lastResetAt = self.status.stats.lastResetAt {
                ResetStatusRow(
                    title: "Last reset",
                    timestamp: Self.localTimestamp.string(from: lastResetAt),
                    detail: self.relativeLastReset)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.orange.opacity(0.16)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.orange.opacity(0.45), lineWidth: 1))
    }

    private func relativeSchedule(_ scheduledFor: Date) -> String {
        let seconds = scheduledFor.timeIntervalSinceNow
        guard seconds > 0 else { return "Reset due now" }
        let hours = max(1, Int((seconds / 3600).rounded(.up)))
        if hours < 48 {
            return "In about \(hours) hour\(hours == 1 ? "" : "s")"
        }
        let days = Int((Double(hours) / 24).rounded(.up))
        return "In about \(days) day\(days == 1 ? "" : "s")"
    }

    private var relativeLastReset: String {
        if let days = self.status.stats.daysSinceLast {
            switch Int(days) {
            case ..<0: break
            case 0: return "Today"
            case 1: return "1 day ago"
            default: return "\(days) days ago"
            }
        }
        guard let lastResetAt = self.status.stats.lastResetAt else { return "Last reset unavailable" }
        return lastResetAt.formatted(.relative(presentation: .named))
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

private struct ResetStatusRow: View {
    let title: String
    let timestamp: String
    let detail: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(self.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(self.timestamp)
                    .font(.caption.monospacedDigit().weight(.medium))
            }
            Spacer(minLength: 8)
            Text(self.detail)
                .font(.caption.weight(.semibold))
                .foregroundStyle(self.title == "Next reset" ? .orange : .primary)
                .multilineTextAlignment(.trailing)
        }
    }
}

private struct AccountCard: View {
    let account: AccountSnapshot
    let isRecommended: Bool
    let isBusy: Bool
    let isRefreshing: Bool
    let action: () -> Void

    var body: some View {
        Button(action: self.action) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 7) {
                    Circle()
                        .fill(self.account.isActive ? Color.green : Color.secondary.opacity(0.35))
                        .frame(width: 7, height: 7)
                    Text(self.account.email)
                        .font(.system(.subheadline, design: .rounded, weight: .semibold))
                        .lineLimit(1)
                    Spacer()
                    if self.isRefreshing {
                        RefreshingBadge(color: .indigo)
                    } else {
                        if self.account.isActive {
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

                if let error = self.account.usageError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                } else if let primary = self.account.primaryWindow {
                    UsageLine(title: "Session", window: primary)
                    if let secondary = self.account.secondaryWindow {
                        UsageLine(title: "Weekly", window: secondary)
                    }
                } else {
                    Text("Usage unavailable")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                let credits = self.account.availableResetCredits(at: Date())
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
            .padding(11)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(self.account.isActive ? Color.accentColor.opacity(0.09) : Color.primary.opacity(0.045)))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(self.isRecommended ? Color.indigo.opacity(0.45) : Color.clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(self.account.isActive || self.isBusy)
    }

    private static func expiryLabel(_ credit: ResetCredit) -> String {
        guard let expiry = credit.expiresAt else { return "No expiry" }
        return expiry.formatted(.dateTime.month(.abbreviated).day())
    }
}

private struct ClaudeCard: View {
    let account: ClaudeAccountSnapshot
    let isRecommended: Bool
    let isBusy: Bool
    let isRefreshing: Bool
    let action: () -> Void

    var body: some View {
        Button(action: self.action) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 7) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(.orange)
                    Text(self.account.email)
                        .font(.system(.subheadline, design: .rounded, weight: .semibold))
                        .lineLimit(1)
                    Spacer()
                    if self.isRefreshing {
                        RefreshingBadge(color: .orange)
                    } else {
                        if self.account.isActive {
                            Badge(text: "ACTIVE", color: .green)
                        }
                        if self.isRecommended {
                            Badge(text: "RECOMMENDED", color: .orange)
                        }
                    }
                    if self.isBusy {
                        ProgressView().controlSize(.mini)
                    }
                }

                if let error = self.account.usageError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                } else if let usage = self.account.usage,
                          let session = usage.fiveHour
                {
                    ClaudeUsageLine(title: "Claude session", window: session)
                    if let weekly = usage.sevenDay {
                        ClaudeUsageLine(title: "Claude weekly", window: weekly)
                    }
                } else {
                    Text("Claude usage unavailable")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(11)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.orange.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .disabled(self.account.isActive || self.isBusy)
    }
}

private struct UsageLine: View {
    let title: String
    let window: UsageWindow

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text(self.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(self.window.remainingPercent, specifier: "%.0f")% left")
                    .font(.caption.monospacedDigit().weight(.semibold))
                if let reset = self.window.resetDate, reset > Date() {
                    Text("· \(reset, style: .relative)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.09))
                    Capsule()
                        .fill(self.barColor)
                        .frame(width: geometry.size.width * self.window.remainingPercent / 100)
                        .animation(.easeOut(duration: 0.6), value: self.window.remainingPercent)
                }
            }
            .frame(height: 5)
        }
    }

    private var barColor: Color {
        switch self.window.remainingPercent {
        case 50...: .green
        case 20...: .orange
        default: .red
        }
    }
}

private struct ClaudeUsageLine: View {
    let title: String
    let window: ClaudeUsageWindow

    var body: some View {
        if let remaining = self.window.remainingPercent {
            VStack(spacing: 4) {
                HStack {
                    Text(self.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(remaining, specifier: "%.0f")% left")
                        .font(.caption.monospacedDigit().weight(.semibold))
                    if let reset = self.window.resetDate, reset > Date() {
                        Text("· \(reset, style: .relative)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.09))
                        Capsule()
                            .fill(self.barColor(remaining: remaining))
                            .frame(width: geometry.size.width * remaining / 100)
                            .animation(.easeOut(duration: 0.6), value: remaining)
                    }
                }
                .frame(height: 5)
            }
        } else {
            EmptyView()
        }
    }

    private func barColor(remaining: Double) -> Color {
        switch remaining {
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
