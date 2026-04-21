import AppKit
import SwiftUI
import UserNotifications

struct MenuBarStatusSummary {
    let attention: Int
    let working: Int
    let completed: Int
    let idle: Int

    static let empty = Self(attention: 0, working: 0, completed: 0, idle: 0)

    var total: Int {
        attention + working + completed + idle
    }

    var ready: Int {
        completed + idle
    }

    func tooltip() -> String {
        guard total > 0 else { return "No sessions detected" }
        return "Needs Input: \(attention) • In Progress: \(working) • Ready: \(ready)"
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var popover: NSPopover?
    var monitor: AgentMonitor?
    var animationTimer: Timer?
    var animFrame = 0
    var isAnimating = false
    var latestSummary = MenuBarStatusSummary.empty

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }

        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatusBar(summary: latestSummary)

        if let button = statusItem?.button {
            button.action = #selector(togglePopover)
            button.target = self
            button.imagePosition = .imageOnly
        }

        popover = NSPopover()
        popover?.contentSize = NSSize(width: 340, height: 480)
        popover?.behavior = .transient
        popover?.animates = true

        monitor = AgentMonitor()
        monitor?.onUpdate = { [weak self] agents in
            DispatchQueue.main.async {
                self?.handleAgentUpdate(agents)
            }
        }
        monitor?.start()

        let contentView = PopoverView(monitor: monitor!)
        popover?.contentViewController = NSHostingController(rootView: contentView)

        // Check for updates
        UpdateChecker.shared.checkOnLaunch()
    }

    func handleAgentUpdate(_ agents: [DetectedAgent]) {
        let needsAttention = agents.filter { $0.status == .needsAttention }
        let working = agents.filter { $0.status == .running || $0.status == .thinking }
        let completed = agents.filter { $0.status == .completed }
        let idle = agents.filter { $0.status == .idle }

        latestSummary = MenuBarStatusSummary(
            attention: needsAttention.count,
            working: working.count,
            completed: completed.count,
            idle: idle.count
        )
        refreshStatusBar()
    }

    func refreshStatusBar() {
        updateStatusBar(summary: latestSummary)
    }

    func updateStatusBar(summary: MenuBarStatusSummary) {
        guard let button = statusItem?.button else { return }

        button.title = ""
        button.attributedTitle = NSAttributedString(string: "")
        button.toolTip = summary.tooltip()
        button.setAccessibilityLabel(summary.tooltip())

        // Stop animation by default; re-start below if needed
        let shouldAnimate = summary.working > 0

        if shouldAnimate {
            renderAnimatedIcon(for: button)
            if !isAnimating { startAnimation() }
        } else {
            if isAnimating { stopAnimation() }
            renderBreakdownIcon(for: button, animated: false)
        }

        if !shouldAnimate && isAnimating {
            stopAnimation()
        }
    }

    // MARK: - Icon Compositing

    /// Composite sparkle + inner ring + outer ring at given opacities
    func compositeIcon(innerAlpha: CGFloat, outerAlpha: CGFloat) -> NSImage? {
        guard let sparkle = NSImage(named: "statusbar-sparkle"),
              let inner = NSImage(named: "statusbar-inner"),
              let outer = NSImage(named: "statusbar-outer") else { return nil }

        let size = sparkle.size
        let img = NSImage(size: size, flipped: false) { rect in
            outer.draw(in: rect, from: .zero, operation: .sourceOver, fraction: outerAlpha)
            inner.draw(in: rect, from: .zero, operation: .sourceOver, fraction: innerAlpha)
            sparkle.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
            return true
        }
        return img
    }

    func constrainToMenuBar(_ img: NSImage?) -> NSImage? {
        guard let original = img else { return nil }
        let maxHeight: CGFloat = 18
        let ratio = maxHeight / original.size.height
        original.size = NSSize(width: original.size.width * ratio, height: maxHeight)
        return original
    }

    func renderBreakdownIcon(for button: NSStatusBarButton, animated: Bool) {
        let img = makeBreakdownIcon(animated: animated)
        img?.isTemplate = false
        button.image = constrainToMenuBar(img)
        button.contentTintColor = nil
        button.alphaValue = latestSummary.total > 0 ? 1.0 : 0.55
    }

    func makeBreakdownIcon(animated: Bool) -> NSImage? {
        let barWidth: CGFloat = 4
        let gap: CGFloat = 2.5
        let trackHeight: CGFloat = 14
        let size = NSSize(width: 17, height: 18)

        let metrics: [(count: Int, color: NSColor)] = [
            (latestSummary.attention, .systemOrange),
            (latestSummary.working, .systemGreen),
            (latestSummary.ready, .systemBlue),
        ]
        let maxCount = max(metrics.map(\.count).max() ?? 0, 1)
        let pulse = animated ? (0.7 + 0.3 * ((sin(CGFloat(animFrame) * 0.3) + 1) / 2)) : 1.0

        let total = latestSummary.total

        return NSImage(size: size, flipped: false) { rect in
            let totalWidth = (barWidth * CGFloat(metrics.count)) + (gap * CGFloat(metrics.count - 1))
            let startX = (rect.width - totalWidth) / 2
            let startY: CGFloat = 2

            if total == 0 {
                for index in metrics.indices {
                    let x = startX + CGFloat(index) * (barWidth + gap)
                    let placeholderRect = CGRect(x: x, y: startY + 6, width: barWidth, height: 8)
                    let placeholderPath = NSBezierPath(
                        roundedRect: placeholderRect,
                        xRadius: barWidth / 2,
                        yRadius: barWidth / 2
                    )
                    NSColor.tertiaryLabelColor.withAlphaComponent(0.22).setFill()
                    placeholderPath.fill()
                }

                return true
            }

            for (index, metric) in metrics.enumerated() {
                guard metric.count > 0 else { continue }

                let x = startX + CGFloat(index) * (barWidth + gap)
                let ratio = CGFloat(metric.count) / CGFloat(maxCount)
                let fillHeight = max(4, 4 + ((trackHeight - 4) * ratio))
                let fillRect = CGRect(
                    x: x,
                    y: startY + (trackHeight - fillHeight),
                    width: barWidth,
                    height: fillHeight
                )
                let fillPath = NSBezierPath(roundedRect: fillRect, xRadius: barWidth / 2, yRadius: barWidth / 2)
                let alpha = index == 1 ? pulse : 1.0
                metric.color.withAlphaComponent(alpha).setFill()
                fillPath.fill()
            }

            return true
        }
    }

    // MARK: - Animation

    func startAnimation() {
        guard !isAnimating else { return }
        isAnimating = true
        animFrame = 0
        animationTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self = self, let button = self.statusItem?.button else { return }
            self.animFrame += 1
            self.renderAnimatedIcon(for: button)
        }
    }

    func stopAnimation() {
        animationTimer?.invalidate()
        animationTimer = nil
        isAnimating = false
        animFrame = 0
    }

    func renderAnimatedIcon(for button: NSStatusBarButton) {
        renderBreakdownIcon(for: button, animated: true)
    }

    // MARK: - Notifications

    func sendNotification(for agents: [DetectedAgent]) {
        for agent in agents {
            let content = UNMutableNotificationContent()
            content.title = "⚠️ Agent Needs Attention"
            content.body = "\(agent.displayName) is waiting for input"
            content.sound = .default

            let request = UNNotificationRequest(
                identifier: "agent-\(agent.pid)",
                content: content,
                trigger: nil
            )
            UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
        }
    }

    @objc func togglePopover() {
        guard let button = statusItem?.button, let popover = popover else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
