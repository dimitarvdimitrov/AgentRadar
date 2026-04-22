import SwiftUI

struct PopoverView: View {
    @ObservedObject var monitor: AgentMonitor

    var body: some View {
        VStack(spacing: 0) {
            HeaderBar(agentCount: monitor.agents.count, lastScan: monitor.lastScan)

            Divider()

            if monitor.agents.isEmpty {
                EmptyStateView()
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 0) {
                        ForEach(monitor.agents) { agent in
                            AgentRowView(agent: agent, monitor: monitor)
                            if agent.id != monitor.agents.last?.id {
                                Divider().padding(.horizontal, 16)
                            }
                        }
                    }
                }
            }

            Divider()
            FooterBar()
        }
        .background(VisualEffectBlur())
        .frame(width: 340)
    }
}

// MARK: - Header

struct HeaderBar: View {
    let agentCount: Int
    let lastScan: Date

    var body: some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.accentColor)
                Text("Agent Radar")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.primary)
            }

            Spacer()

            HStack(spacing: 6) {
                if agentCount > 0 {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 6, height: 6)
                        .overlay(
                            Circle()
                                .stroke(Color.green.opacity(0.3), lineWidth: 3)
                                .scaleEffect(1.5)
                                .animation(.easeOut(duration: 1).repeatForever(autoreverses: true), value: agentCount)
                        )
                } else {
                    Circle()
                        .fill(Color.secondary.opacity(0.5))
                        .frame(width: 6, height: 6)
                }

                Text(agentCount == 0 ? "No agents" : "\(agentCount) active")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.5))
    }
}

// MARK: - Agent Row

struct AgentRowView: View {
    @ObservedObject var agent: DetectedAgent
    var monitor: AgentMonitor

    var statusColor: Color {
        switch agent.status {
        case .thinking:  return Color(red: 0.13, green: 0.66, blue: 0.58)
        case .running:   return Color(red: 0.22, green: 0.49, blue: 0.96)
        case .needsAttention: return Color(red: 0.95, green: 0.55, blue: 0.18)
        case .idle:      return Color.secondary
        case .completed: return Color(red: 0.18, green: 0.66, blue: 0.34)
        }
    }

    var statusIcon: String {
        switch agent.status {
        case .thinking:  return "sparkles"
        case .running:   return "bolt.fill"
        case .needsAttention: return "exclamationmark.triangle.fill"
        case .idle:      return "pause.fill"
        case .completed: return "checkmark"
        }
    }

    @ViewBuilder
    var secondaryMetadata: some View {
        if !agent.branchDisplayLabel.isEmpty {
            Text(agent.branchDisplayLabel)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        } else if let appName = agent.appName, !appName.isEmpty {
            Text(appName)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        } else {
            Text(agent.kind.displayName)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    var body: some View {
        Button(action: { monitor.activateAgent(agent) }) {
            HStack(spacing: 14) {
                AgentAvatarTileView(
                    customIconName: agent.kind.customIcon,
                    symbolName: agent.kind.icon,
                    statusSymbolName: statusIcon,
                    statusTint: statusColor
                )
                .padding(.trailing, 4)

                VStack(alignment: .leading, spacing: 6) {
                    Text(agent.directoryDisplayName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    secondaryMetadata
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 6) {
                    Text(agent.lastActivityString)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                        .help(
                            """
                            Last activity: \(agent.lastActivityString)
                            Session age: \(agent.uptimeString)
                            Status source: \(agent.statusDebugSource.isEmpty ? "unknown" : agent.statusDebugSource)
                            \(agent.statusDebugDetails.isEmpty ? "No debug details yet" : agent.statusDebugDetails)
                            """
                        )

                    Image(systemName: "arrow.up.forward.app")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary.opacity(0.7))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(agent.status == .needsAttention ? Color.orange.opacity(0.15) : Color.clear)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
        )
    }
}

struct AgentAvatarTileView: View {
    let customIconName: String?
    let symbolName: String
    let statusSymbolName: String
    let statusTint: Color

    var body: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        Color.primary.opacity(0.08),
                        Color.primary.opacity(0.03)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
            .overlay(alignment: .topLeading) {
                Circle()
                    .fill(Color.white.opacity(0.30))
                    .frame(width: 20, height: 20)
                    .blur(radius: 10)
                    .offset(x: -2, y: -2)
            }
            .frame(width: 40, height: 40)
            .overlay {
                if let customIconName {
                    Image(customIconName)
                        .renderingMode(.template)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 20, height: 20)
                        .foregroundStyle(Color.primary.opacity(0.78))
                } else {
                    Image(systemName: symbolName)
                        .font(.system(size: 18, weight: .semibold))
                        .symbolRenderingMode(.monochrome)
                        .foregroundStyle(Color.primary.opacity(0.78))
                }
            }
            .overlay(alignment: .bottomTrailing) {
                StatusGlyphBadgeView(
                    symbolName: statusSymbolName,
                    tint: statusTint
                )
                .offset(x: 4, y: 4)
            }
    }
}

struct StatusGlyphBadgeView: View {
    let symbolName: String
    let tint: Color

    var body: some View {
        ZStack {
            Circle()
                .fill(Color(nsColor: .windowBackgroundColor))
                .frame(width: 18, height: 18)
                .shadow(color: Color.black.opacity(0.08), radius: 1, x: 0, y: 1)

            Circle()
                .fill(tint.opacity(0.16))
                .frame(width: 14, height: 14)

            Image(systemName: symbolName)
                .font(.system(size: 8, weight: .bold))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(tint)
        }
    }
}

// MARK: - Animated Text

struct AnimatedGradientText: View {
    let text: String
    @State private var isAnimating = false

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(.secondary)
            .overlay(
                GeometryReader { geo in
                    LinearGradient(
                        colors: [.clear, .primary, .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: geo.size.width * 2)
                    .offset(x: isAnimating ? geo.size.width : -geo.size.width * 2)
                }
            )
            .mask(Text(text).font(.system(size: 12, weight: .medium)))
            .onAppear {
                withAnimation(.linear(duration: 2.0).repeatForever(autoreverses: false)) {
                    isAnimating = true
                }
            }
    }
}

struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            ZStack {
                Circle()
                    .fill(Color.secondary.opacity(0.1))
                    .frame(width: 80, height: 80)
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 32, weight: .light))
                    .foregroundColor(.secondary.opacity(0.6))
            }
            
            VStack(spacing: 6) {
                Text("No agents detected")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.primary)
                Text("Start Claude Code, Codex, Gemini CLI,\nor any AI coding agent to see it here.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
            }
            .padding(.horizontal, 32)
            Spacer()
        }
        .frame(height: 280)
    }
}

struct FooterBar: View {
    var body: some View {
        HStack {
            Text("Agent Radar")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary.opacity(0.6))

            Spacer()

            Button(action: {
                UpdateChecker.shared.checkForUpdate()
            }) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
            .onHover { isHovered in
                if isHovered { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
            .help("Check for updates")

            Button(action: {
                NSApplication.shared.terminate(nil)
            }) {
                HStack(spacing: 4) {
                    Text("Quit")
                    Image(systemName: "power")
                }
                .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
            .onHover { isHovered in
                if isHovered {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.5))
    }
}

// MARK: - Visual Effect Blur

struct VisualEffectBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.state = .active
        view.material = .menu
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

// MARK: - Color Extension

extension Color {
    init?(hex: String) {
        var str = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if str.hasPrefix("#") { str.removeFirst() }
        guard str.count == 6, let val = UInt64(str, radix: 16) else { return nil }
        self.init(
            red:   Double((val >> 16) & 0xFF) / 255,
            green: Double((val >> 8)  & 0xFF) / 255,
            blue:  Double( val        & 0xFF) / 255
        )
    }
}
