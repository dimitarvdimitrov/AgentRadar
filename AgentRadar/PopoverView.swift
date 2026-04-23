import SwiftUI

private enum SessionListMode: String, CaseIterable, Identifiable {
    case flat
    case grouped

    var id: String { rawValue }

    var symbolName: String {
        switch self {
        case .flat:
            return "list.bullet"
        case .grouped:
            return "square.stack.3d.up"
        }
    }

    var helpText: String {
        switch self {
        case .flat:
            return "Show a single flat session list"
        case .grouped:
            return "Group sessions by branch or working directory"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .flat:
            return "Recent sessions"
        case .grouped:
            return "Grouped by branch"
        }
    }
}

private struct BranchSection: Identifiable {
    let id: String
    let title: String
    let subtitle: String?
    let isBranchBacked: Bool
    var agents: [DetectedAgent]

    static func build(from agents: [DetectedAgent]) -> [BranchSection] {
        var sections: [BranchSection] = []
        var sectionIndexByID: [String: Int] = [:]

        for agent in agents {
            let sectionID = self.sectionID(for: agent)

            if let existingIndex = sectionIndexByID[sectionID] {
                sections[existingIndex].agents.append(agent)
                continue
            }

            let section = self.makeSection(for: agent, id: sectionID)
            sectionIndexByID[sectionID] = sections.count
            sections.append(section)
        }

        return sections
    }

    private static func makeSection(for agent: DetectedAgent, id: String) -> BranchSection {
        let branchName = self.trimmedValue(agent.gitBranch)

        if let branchName, !branchName.isEmpty {
            return BranchSection(
                id: id,
                title: branchName,
                subtitle: self.branchSubtitle(for: agent),
                isBranchBacked: true,
                agents: [agent]
            )
        }

        return BranchSection(
            id: id,
            title: self.branchlessTitle(for: agent),
            subtitle: self.branchlessSubtitle(for: agent),
            isBranchBacked: false,
            agents: [agent]
        )
    }

    private static func sectionID(for agent: DetectedAgent) -> String {
        let branchName = self.trimmedValue(agent.gitBranch)
        let repoRoot = self.normalizedPath(agent.gitRepoRoot ?? "")
        let branchContext = repoRoot.isEmpty ? self.normalizedPath(agent.workingDirectory) : repoRoot

        if let branchName, !branchName.isEmpty {
            return "branch:\(branchContext)|\(branchName)"
        }

        let workingDirectory = self.normalizedPath(agent.workingDirectory)
        if !workingDirectory.isEmpty {
            return "directory:\(workingDirectory)"
        }

        return "agent:\(agent.id)"
    }

    private static func branchSubtitle(for agent: DetectedAgent) -> String? {
        let repoName = self.displayName(forPath: agent.gitRepoRoot)
        if !repoName.isEmpty {
            return repoName
        }

        let workingDirectory = self.normalizedPath(agent.workingDirectory)
        guard !workingDirectory.isEmpty else { return nil }
        return NSString(string: workingDirectory).abbreviatingWithTildeInPath
    }

    private static func branchlessTitle(for agent: DetectedAgent) -> String {
        let displayName = agent.directoryDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !displayName.isEmpty {
            return displayName
        }

        let workingDirectory = self.normalizedPath(agent.workingDirectory)
        if !workingDirectory.isEmpty {
            let lastComponent = URL(fileURLWithPath: workingDirectory).lastPathComponent
            if !lastComponent.isEmpty {
                return lastComponent
            }

            return NSString(string: workingDirectory).abbreviatingWithTildeInPath
        }

        return agent.kind.displayName
    }

    private static func branchlessSubtitle(for agent: DetectedAgent) -> String? {
        let workingDirectory = self.normalizedPath(agent.workingDirectory)
        let repoRoot = self.normalizedPath(agent.gitRepoRoot ?? "")

        guard !workingDirectory.isEmpty else { return nil }

        if !repoRoot.isEmpty {
            let repoName = self.displayName(forPath: repoRoot)
            if workingDirectory == repoRoot {
                return repoName.isEmpty ? "No branch" : "No branch in \(repoName)"
            }

            if let relativePath = self.relativePath(from: repoRoot, to: workingDirectory) {
                if repoName.isEmpty {
                    return "No branch • \(relativePath)"
                }

                return "No branch • \(repoName)/\(relativePath)"
            }

            if !repoName.isEmpty {
                return "No branch in \(repoName)"
            }
        }

        let abbreviatedPath = NSString(string: workingDirectory).abbreviatingWithTildeInPath
        return "Directory • \(abbreviatedPath)"
    }

    private static func relativePath(from basePath: String, to fullPath: String) -> String? {
        guard fullPath.hasPrefix(basePath + "/") else { return nil }
        let relativePath = String(fullPath.dropFirst(basePath.count + 1))

        guard !relativePath.isEmpty else { return nil }
        return relativePath
    }

    private static func displayName(forPath path: String?) -> String {
        let normalizedPath = self.normalizedPath(path ?? "")
        guard !normalizedPath.isEmpty else { return "" }

        let lastComponent = URL(fileURLWithPath: normalizedPath).lastPathComponent
        if !lastComponent.isEmpty {
            return lastComponent
        }

        return NSString(string: normalizedPath).abbreviatingWithTildeInPath
    }

    private static func normalizedPath(_ path: String) -> String {
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedPath.hasPrefix("/") else { return trimmedPath }
        return (trimmedPath as NSString).standardizingPath
    }

    private static func trimmedValue(_ value: String?) -> String? {
        value?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct PopoverView: View {
    @ObservedObject var monitor: AgentMonitor
    @AppStorage("popoverSessionListMode") private var sessionListModeRawValue = SessionListMode.flat.rawValue
    @State private var expandedSectionID: String?

    private var sessionListMode: SessionListMode {
        SessionListMode(rawValue: sessionListModeRawValue) ?? .flat
    }

    private var sessionListModeBinding: Binding<SessionListMode> {
        Binding(
            get: { self.sessionListMode },
            set: { self.sessionListModeRawValue = $0.rawValue }
        )
    }

    private var branchSections: [BranchSection] {
        BranchSection.build(from: monitor.agents)
    }

    private var branchSectionSignature: String {
        branchSections.map(\.id).joined(separator: "|")
    }

    var body: some View {
        VStack(spacing: 0) {
            HeaderBar(
                agentCount: monitor.agents.count,
                lastScan: monitor.lastScan,
                listMode: sessionListModeBinding
            )

            Divider()

            if monitor.agents.isEmpty {
                EmptyStateView()
            } else {
                sessionListContent
            }

            Divider()
            FooterBar()
        }
        .background(VisualEffectBlur())
        .frame(width: 340)
        .onChange(of: branchSectionSignature) { _ in
            reconcileExpandedSection()
        }
    }

    @ViewBuilder
    private var sessionListContent: some View {
        ScrollView(.vertical, showsIndicators: false) {
            if sessionListMode == .flat {
                AgentRowsView(agents: monitor.agents, monitor: monitor)
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(branchSections) { section in
                        BranchSectionView(
                            section: section,
                            isExpanded: expandedSectionID == section.id,
                            monitor: monitor
                        ) {
                            toggleSection(section)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            }
        }
    }

    private func toggleSection(_ section: BranchSection) {
        withAnimation(.easeInOut(duration: 0.16)) {
            if expandedSectionID == section.id {
                expandedSectionID = nil
            } else {
                expandedSectionID = section.id
            }
        }
    }

    private func reconcileExpandedSection() {
        guard let expandedSectionID else { return }

        let sectionStillExists = branchSections.contains { $0.id == expandedSectionID }
        if !sectionStillExists {
            self.expandedSectionID = nil
        }
    }
}

// MARK: - Header

private struct HeaderBar: View {
    let agentCount: Int
    let lastScan: Date
    @Binding var listMode: SessionListMode

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.accentColor)
                Text("Agent Radar")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.primary)
            }

            Spacer(minLength: 12)

            if agentCount > 0 {
                SessionListModeToggle(listMode: $listMode)
            }

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

private struct SessionListModeToggle: View {
    @Binding var listMode: SessionListMode

    var body: some View {
        HStack(spacing: 2) {
            ForEach(SessionListMode.allCases) { mode in
                Button {
                    withAnimation(.easeInOut(duration: 0.14)) {
                        listMode = mode
                    }
                } label: {
                    Image(systemName: mode.symbolName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(listMode == mode ? .white : .secondary)
                        .frame(width: 28, height: 24)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(listMode == mode ? Color.accentColor : Color.clear)
                        )
                }
                .buttonStyle(.plain)
                .help(mode.helpText)
                .accessibilityLabel(mode.accessibilityLabel)
            }
        }
        .padding(2)
        .background(
            Capsule(style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .help("Switch between the flat list and grouped branch view")
    }
}

private struct AgentRowsView: View {
    let agents: [DetectedAgent]
    let monitor: AgentMonitor

    var body: some View {
        LazyVStack(spacing: 0) {
            ForEach(Array(agents.enumerated()), id: \.element.id) { index, agent in
                AgentRowView(agent: agent, monitor: monitor)

                if index < agents.count - 1 {
                    Divider().padding(.horizontal, 16)
                }
            }
        }
    }
}

private struct BranchSectionView: View {
    let section: BranchSection
    let isExpanded: Bool
    let monitor: AgentMonitor
    let toggle: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Button(action: toggle) {
                HStack(spacing: 10) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 12)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(section.title)
                            .font(.system(
                                size: 13,
                                weight: .semibold,
                                design: section.isBranchBacked ? .monospaced : .default
                            ))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                            .truncationMode(section.isBranchBacked ? .middle : .tail)

                        if let subtitle = section.subtitle, !subtitle.isEmpty {
                            Text(subtitle)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }

                    Spacer(minLength: 12)

                    Text("\(section.agents.count)")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(Color.primary.opacity(isExpanded ? 0.10 : 0.06))
                        )
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                Divider()
                    .padding(.leading, 34)

                AgentRowsView(agents: section.agents, monitor: monitor)
                    .padding(.vertical, 4)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(isExpanded ? 0.055 : 0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(isExpanded ? 0.10 : 0.06), lineWidth: 1)
        )
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
