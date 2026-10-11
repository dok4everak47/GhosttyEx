#if os(macOS)
import AppKit
import SwiftUI

// MARK: - Shared pieces

/// A dot that radiates while the server is live. Core Animation, so it costs no
/// SwiftUI layout per frame (a `repeatForever` here re-laid out the whole window).
struct LocalhostPulse: View {
    let color: Color
    let active: Bool
    var size: CGFloat = 8

    var body: some View {
        RadiateDotLayer(color: color, active: active, size: size)
            .frame(width: size * 2.6, height: size * 2.6)
    }
}

/// The framework's badge: symbol and name in its color.
struct LocalhostFrameworkBadge: View {
    let framework: LocalhostFramework
    var compact = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: framework.symbol).font(.system(size: compact ? 9 : 10, weight: .bold))
            if !compact { Text(framework.name).font(.system(size: 10.5, weight: .semibold)) }
        }
        .foregroundColor(framework.color)
        .padding(.horizontal, compact ? 5 : 7)
        .padding(.vertical, 2.5)
        .background(Capsule().fill(framework.color.opacity(0.16)))
        .overlay(Capsule().stroke(framework.color.opacity(0.35), lineWidth: 0.5))
        .fixedSize()
    }
}

/// `localhost:5173 ↗`: the thing you click to open the app.
struct LocalhostURLPill: View {
    let session: LocalhostSession
    var large = false
    @State private var hovering = false

    var body: some View {
        let accent = session.project.color
        Button {
            LocalhostSessions.shared.openInBrowser(session.url)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "globe").font(.system(size: large ? 12 : 10, weight: .semibold))
                if let port = session.ports.first {
                    Text("localhost").foregroundColor(.primary.opacity(0.75))
                        + Text(verbatim: ":\(port)").foregroundColor(.primary).bold()
                } else {
                    Text(session.state == .starting ? "starting…" : "not listening")
                        .foregroundColor(.secondary)
                }
                if session.url != nil {
                    Image(systemName: "arrow.up.right").font(.system(size: large ? 10 : 8.5, weight: .bold))
                        .foregroundColor(accent)
                }
            }
            .font(.system(size: large ? 14 : 12, design: .monospaced))
            .padding(.horizontal, large ? 12 : 9)
            .padding(.vertical, large ? 6 : 4)
            .background(
                Capsule().fill(
                    LinearGradient(colors: [accent.opacity(hovering ? 0.36 : 0.24), Color.cyan.opacity(hovering ? 0.22 : 0.12)],
                                   startPoint: .leading, endPoint: .trailing)))
            .overlay(Capsule().stroke(accent.opacity(0.55), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(session.url == nil)
        .onHover { hovering = $0 }
        .help(session.url.map { "Open \($0.absoluteString) in your browser" } ?? "")
    }
}

/// Round icon button used on cards.
struct LocalhostIconButton: View {
    let symbol: String
    let help: String
    var tint: Color = .secondary
    var size: CGFloat = 22
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.46, weight: .bold))
                .foregroundColor(hovering ? tint : .secondary)
                .frame(width: size, height: size)
                .background(Circle().fill(Color.primary.opacity(hovering ? 0.14 : 0.06)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

func localhostUptime(since date: Date?, now: Date) -> String {
    guard let date else { return "" }
    let seconds = max(0, Int(now.timeIntervalSince(date)))
    if seconds < 60 { return "\(seconds)s" }
    if seconds < 3600 { return "\(seconds / 60)m" }
    return "\(seconds / 3600)h \(seconds % 3600 / 60)m"
}

// MARK: - Sidebar

/// Sidebar header button: opens the localhost manager, with the live count.
struct LocalhostHeaderButton: View {
    @ObservedObject private var store = LocalhostSessions.shared
    @State private var hovering = false

    var body: some View {
        Button(action: LocalhostManager.toggle) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "globe")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(store.liveCount > 0
                        ? AnyShapeStyle(LinearGradient(colors: [.cyan, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
                        : AnyShapeStyle(Color.primary))
                    .frame(width: 30, height: 26)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(hovering ? 0.08 : 0.03)))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.14), lineWidth: 1))
                if store.liveCount > 0 {
                    Text("\(store.liveCount)")
                        .font(.system(size: 8.5, weight: .heavy))
                        .foregroundColor(.black)
                        .frame(minWidth: 13, minHeight: 13)
                        .background(Circle().fill(Color(red: 0.25, green: 0.92, blue: 0.55)))
                        .offset(x: 4, y: -4)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Localhost manager (⌃⌘L)")
    }
}

// MARK: - Toast

/// "Your app is live" pop-up shown over the terminal when a session starts listening.
struct LocalhostToastView: View {
    let session: LocalhostSession
    var controller: TerminalController?
    let dismiss: () -> Void

    var body: some View {
        let accent = session.project.color
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(LinearGradient(colors: [accent, .cyan], startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: "globe").font(.system(size: 17, weight: .bold)).foregroundColor(.white)
            }
            .frame(width: 38, height: 38)
            .shadow(color: accent.opacity(0.6), radius: 8)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("\(session.project.name) is live").font(.system(size: 13, weight: .semibold))
                    LocalhostFrameworkBadge(framework: session.framework, compact: true)
                }
                Text(session.agent.map { "Started by \($0.displayName) in its own tab · keeps running after it's done" }
                     ?? "Running in its own tab")
                    .font(.system(size: 11)).foregroundColor(.secondary).lineLimit(1)
            }
            LocalhostURLPill(session: session, large: true)
            VisualFixLaunchButton(url: session.url, controller: controller, large: true)
            LocalhostIconButton(symbol: "xmark", help: "Dismiss", size: 20, action: dismiss)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 14).fill(.ultraThickMaterial)
                RoundedRectangle(cornerRadius: 14)
                    .fill(LinearGradient(colors: [accent.opacity(0.2), Color.cyan.opacity(0.08)], startPoint: .leading, endPoint: .trailing))
            })
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(LinearGradient(colors: [accent, .cyan.opacity(0.6)], startPoint: .leading, endPoint: .trailing), lineWidth: 1.2))
        .shadow(color: .black.opacity(0.4), radius: 18, y: 8)
        .fixedSize()
    }
}

/// Places the toast at the top of the terminal area.
struct LocalhostToastLayer: View {
    var controller: TerminalController?
    @ObservedObject private var store = LocalhostSessions.shared

    var body: some View {
        VStack {
            if let session = store.toast {
                LocalhostToastView(session: session, controller: controller) { store.toast = nil }
                    .padding(.top, 14)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .onTapGesture { LocalhostSessions.shared.focus(session) }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .animation(.spring(response: 0.45, dampingFraction: 0.8), value: store.toast?.id)
    }
}
#endif
