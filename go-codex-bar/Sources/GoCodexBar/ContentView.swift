import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("restartAfterSwitch") private var restartAfterSwitch = true
    @State private var confirmsLogout = false

    var body: some View {
        VStack(spacing: 0) {
            self.header
            Divider()
            self.accountList
        }
        .frame(width: 430, height: 660)
        .background(.ultraThinMaterial)
        .task {
            if self.model.accounts.isEmpty {
                await self.model.refresh()
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
            .disabled(self.model.accounts.isEmpty || self.model.busyEmail != nil)

            Button {
                Task { await self.model.maxing() }
            } label: {
                Label("Maxing", systemImage: "sparkles")
            }
            .buttonStyle(.borderedProminent)
            .disabled(self.model.recommendedEmail == nil || self.model.busyEmail != nil)

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
            .disabled(self.model.isRefreshing)
            .help("Refresh usage")

            Menu {
                Button("Save Current", systemImage: "square.and.arrow.down") {
                    Task { await self.model.saveCurrent() }
                }
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
    private var accountList: some View {
        if self.model.accounts.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "person.crop.circle.badge.plus")
                    .font(.system(size: 32))
                    .foregroundStyle(.secondary)
                Text("No saved accounts")
                    .font(.headline)
                Text("Sign in with Codex, then save the current account.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Save Current") {
                    Task { await self.model.saveCurrent() }
                }
                .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(30)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(self.sortedAccounts) { account in
                            AccountCard(
                                account: account,
                                isRecommended: account.email == self.model.recommendedEmail,
                                isBusy: account.email == self.model.busyEmail)
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
}

private struct AccountCard: View {
    let account: AccountSnapshot
    let isRecommended: Bool
    let isBusy: Bool
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
                    if self.account.isActive {
                        Badge(text: "ACTIVE", color: .green)
                    }
                    if self.isRecommended {
                        Badge(text: "RECOMMENDED", color: .indigo)
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
