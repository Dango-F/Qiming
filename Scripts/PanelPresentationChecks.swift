// Compile with the production panel, popover and component sources; never with AppModel.swift.
// This model simulates async replies only. No XPC, IOKit, pmset or preference changes occur.
import AppKit
import Foundation
import QuartzCore

enum Language: String { case chinese, english }
@MainActor enum Localization {
    static var language = Language.chinese
    static var locale: Locale { Locale(identifier: language == .chinese ? "zh-Hans" : "en") }
    static func clock(_ seconds: TimeInterval, roundingUp: Bool = false) -> String {
        SessionTiming.clock(seconds, roundingUp: roundingUp)
    }
}
@MainActor func L(_ key: String) -> String {
    let language = Localization.language == .chinese ? "zh-Hans" : "en"
    let resources = ProcessInfo.processInfo.environment["QIMING_QA_RESOURCES"] ?? "/Applications/Qiming.app/Contents/Resources"
    return Bundle(path: resources + "/" + language + ".lproj")?.localizedString(forKey: key, value: key, table: "Localizable") ?? key
}

@MainActor final class PresentationHelper {
    var ready = true
    var statusKey: String { ready ? "helper.connected" : "helper.missing" }
    func register() async throws { ready = true }
}
@MainActor final class AppModel {
    let helper = PresentationHelper()
    var busy = false
    var status: HelperStatus?
    var messageKey: String?
    var technicalError: String?
    var connectionUnverified = false
    var externalBlockers: [ExternalSleepBlocker] = []
    var glassAppearance = GlassAppearanceVariant.backupBlack
    var glassFontColor = GlassFontColor.black
    var glassTransparency = 0.75
    var duration: TimeInterval = 0
    private var untilDate: Date?
    var panelDuration: (seconds: TimeInterval, until: Date?) { (duration, untilDate) }
    var starts: [DisplayMode] = []
    var stops = 0
    var power = PowerSnapshot(onAC: false, battery: 80, charging: false, lidClosed: false, sleepDisabled: false)
    private var listeners: [UUID: () -> Void] = [:]
    var mode: DisplayMode { status?.session?.mode ?? .system }
    var session: Session? { status?.session }
    var isActive: Bool { status?.phase == "active" }
    func stage(_ mode: DisplayMode, deadline: Date? = nil) {
        status = HelperStatus(session: mode == .system ? nil : Session(mode: mode, deadline: deadline, policy: ProtectionPolicy()),
            power: power, phase: mode == .system ? "idle" : "active", systemAssertion: mode != .system,
            displayAssertion: mode != .system, manualDisplayOff: false, screenSaverPaused: false, recovery: [])
        changed()
    }
    func observe(_ listener: @escaping () -> Void) -> UUID { let id = UUID(); listeners[id] = listener; return id }
    func changed() { for listener in Array(listeners.values) { listener() } }
    func clearMessage() { messageKey = nil; technicalError = nil; changed() }
    func refresh() async { changed() }
    func start(_ mode: DisplayMode) async {
        starts.append(mode)
        busy = true; clearMessage()
        try? await Task.sleep(for: .milliseconds(15))
        stage(mode); busy = false; changed()
    }
    func stop() async {
        stops += 1
        busy = true; changed()
        try? await Task.sleep(for: .milliseconds(15))
        stage(.system); busy = false; changed()
    }
    func screenOff() async {}
    func changePanelDuration(_ seconds: TimeInterval, until date: Date? = nil) async {
        duration = seconds
        untilDate = date
        status?.session?.deadline = date ?? (seconds > 0 ? Date().addingTimeInterval(seconds) : nil)
        changed()
    }
    func extendSession() async {}
    func fail(_ error: Error) { technicalError = error.localizedDescription; changed() }
}

@main @MainActor struct PanelPresentationChecks {
    static func indicator(in view: NSView) -> PanelStatusIndicator? {
        if let match = view as? PanelStatusIndicator { return match }
        return view.subviews.lazy.compactMap { indicator(in: $0) }.first
    }
    static func texts(in view: NSView) -> [String] {
        guard !view.isHidden else { return [] }
        return (view as? NSTextField).map { [$0.stringValue] } ?? view.subviews.flatMap { texts(in: $0) }
    }
    static func buttons(in view: NSView) -> [ActionButton] {
        guard !view.isHidden else { return [] }
        if let button = view as? ActionButton { return [button] }
        return view.subviews.flatMap { buttons(in: $0) }
    }
    static func modeRows(in view: NSView) -> [ModeRow] {
        if let row = view as? ModeRow { return [row] }
        return view.subviews.flatMap { modeRows(in: $0) }
    }
    static func durationPopup(in view: NSView) -> PanelDurationPopup? {
        if let popup = view as? PanelDurationPopup { return popup }
        return view.subviews.lazy.compactMap { durationPopup(in: $0) }.first
    }
    static func main() async {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        let expectFixed = CommandLine.arguments.contains("--expect-fixed")
        var failures: [String] = []
        let screenFrame = NSScreen.main!.frame
        let anchorWindow = NSWindow(contentRect: NSRect(x: screenFrame.midX, y: screenFrame.maxY - 24, width: 24, height: 24),
                                    styleMask: .borderless, backing: .buffered, defer: false)
        anchorWindow.isReleasedWhenClosed = false
        let anchor = NSView(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        anchorWindow.contentView = anchor

        // An unattached menu-bar anchor must never order a default-origin panel on screen.
        let invalid = GlassPopover()
        invalid.animates = false
        invalid.contentViewController = PanelController(model: AppModel())
        invalid.show(relativeTo: NSRect(x: 0, y: 0, width: 24, height: 24), of: NSView(), preferredEdge: .minY)
        if invalid.isShown { failures.append("unattached anchor displayed a window") }
        invalid.performClose(nil)
        let validAnchorFrame = anchorWindow.frame
        for origin in [NSPoint.zero, NSPoint(x: 0, y: -24)] {
            anchorWindow.setFrame(NSRect(origin: origin, size: NSSize(width: 24, height: 24)), display: false)
            invalid.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
            if invalid.isShown { failures.append("non-empty provisional anchor at \(origin) displayed a bottom-left panel") }
            invalid.performClose(nil)
        }
        anchorWindow.setFrame(NSRect(x: 0, y: 0, width: 24, height: 0), display: false)
        invalid.show(relativeTo: NSRect(x: 0, y: 0, width: 24, height: 24), of: anchor, preferredEdge: .minY)
        if invalid.isShown { failures.append("zero-height anchor window displayed a panel") }
        invalid.performClose(nil)
        anchorWindow.setFrame(validAnchorFrame, display: false)

        let displays = [NSRect(x: 0, y: 0, width: 1728, height: 1117), NSRect(x: -1920, y: -200, width: 1920, height: 1080)]
        for (rect, expected) in [
            (NSRect(x: 0, y: 0, width: 38, height: 33), nil as Int?),
            (NSRect(x: 0, y: -33, width: 38, height: 33), nil),
            (NSRect(x: 1235, y: 1084, width: 50, height: 33), 0),
            (NSRect(x: -1400, y: 847, width: 38, height: 33), 1),
            (NSRect(x: -1400, y: 300, width: 38, height: 33), nil)
        ] {
            if MenuBarAnchorGeometry.screenIndex(for: rect, screens: displays) != expected {
                failures.append("menu-bar screen validation failed: \(rect)")
            }
        }

        let startupPanel = PanelController(model: AppModel())
        let startupPopover = GlassPopover(); startupPopover.animates = false
        startupPopover.contentViewController = startupPanel
        anchorWindow.setFrame(NSRect(x: 0, y: 0, width: 24, height: 24), display: false)
        let delayedShow = Task { await startupPopover.showWhenAnchored(of: anchor, preferredEdge: .minY) }
        try? await Task.sleep(for: .milliseconds(40))
        if startupPopover.isShown { failures.append("startup showed before anchor readiness") }
        anchorWindow.setFrame(validAnchorFrame, display: false)
        if !(await delayedShow.value) || !startupPopover.isShown { failures.append("startup did not show after anchor readiness") }
        if let window = startupPanel.view.window, window.frame.minY < screenFrame.midY {
            failures.append("startup panel remained at bottom-left after attachment")
        }
        let movedAnchorFrame = validAnchorFrame.offsetBy(dx: -160, dy: 0)
        anchorWindow.setFrame(movedAnchorFrame, display: false)
        NotificationCenter.default.post(name: NSWindow.didMoveNotification, object: anchorWindow)
        try? await Task.sleep(for: .milliseconds(300))
        if let window = startupPanel.view.window, abs(window.frame.midX - movedAnchorFrame.midX) > 1 {
            failures.append("panel did not follow a menu-bar anchor position change")
        }
        startupPopover.performClose(nil)
        anchorWindow.setFrame(NSRect(x: 0, y: 0, width: 24, height: 0), display: false)
        let canceledShow = Task { await startupPopover.showWhenAnchored(of: anchor, preferredEdge: .minY) }
        canceledShow.cancel()
        if await canceledShow.value { failures.append("canceled startup still showed") }
        anchorWindow.setFrame(validAnchorFrame, display: false)
        print("CHECK startup: rejects nonempty origin anchors, waits for stable menu-bar position, follows anchor changes, handles multiple displays, canceled request stays hidden")

        // Independent first-use model: no saved session and no approved helper.
        // This does not clear the real application's preferences or system approval.
        let firstUseModel = AppModel(); firstUseModel.helper.ready = false
        let firstUsePanel = PanelController(model: firstUseModel)
        firstUsePanel.choose(.closed)
        let firstUsePopover = GlassPopover(); firstUsePopover.animates = false
        firstUsePopover.contentViewController = firstUsePanel
        for launch in 0..<3 {
            anchorWindow.setFrame(NSRect(x: 0, y: 0, width: 24, height: 24), display: false)
            let opening = Task { await firstUsePopover.showWhenAnchored(of: anchor, preferredEdge: .minY) }
            try? await Task.sleep(for: .milliseconds(60))
            if firstUsePopover.isShown { failures.append("first-use/reopen \(launch) showed at provisional origin") }
            anchorWindow.setFrame(validAnchorFrame, display: false)
            if !(await opening.value) { failures.append("first-use/reopen \(launch) failed to show at the menu bar") }
            if let window = firstUsePanel.view.window,
               abs(window.frame.maxY - (min(validAnchorFrame.minY, NSScreen.main!.visibleFrame.maxY) - 6)) > 1 {
                failures.append("first-use/reopen \(launch) top edge was not anchored: window=\(window.frame), anchor=\(validAnchorFrame), bounds=\(anchor.bounds), visible=\(NSScreen.main!.visibleFrame)")
            }
            firstUsePopover.performClose(nil)
        }
        print("CHECK first-use/reopen: missing-helper content, three delayed valid anchors, no provisional window")
        if CommandLine.arguments.contains("--startup-only") {
            for failure in failures { print("FAIL \(failure)") }
            print("\(failures.isEmpty ? "PASS" : "DIAGNOSTIC"): startup/reopen checks; \(failures.count) failures")
            exit(failures.isEmpty ? 0 : 1)
        }

        let pulseModel = AppModel()
        let pulsePanel = PanelController(model: pulseModel)
        let pulsePopover = GlassPopover(); pulsePopover.animates = false
        pulsePopover.contentViewController = pulsePanel
        pulsePopover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            print("SKIP live pulse samples: system Reduce Motion enabled")
        } else {
            for mode in [DisplayMode.system, .closed] {
                pulseModel.stage(mode)
                pulsePanel.view.layoutSubtreeIfNeeded()
                guard let status = indicator(in: pulsePanel.view),
                      let light = status.layer?.sublayers?.first(where: { $0.name == "qiming.status.light" }) else {
                    failures.append("missing native status light"); continue
                }
                status.setPresented(true)
                if let shape = light as? CAShapeLayer {
                    if shape.fillColor == nil || shape.fillColor?.alpha != 1 || shape.lineWidth != 0 {
                        failures.append("status light must have an opaque solid core: \(mode)")
                    }
                }
                guard let beginTime = light.animation(forKey: "qiming.breathe")?.beginTime else {
                    failures.append("pulse not started on first visible frame: \(mode)"); continue
                }
                var opacity: [Float] = []
                var scales: [CGFloat] = []
                var glow: [Float] = []
                var spread: [CGFloat] = []
                for _ in 0..<7 {
                    try? await Task.sleep(for: .milliseconds(240))
                    // Match the real once-per-second refresh without restarting the animation.
                    status.update(mode == .system ? .system : .running, details: "presentation test")
                    if let presentation = light.presentation() {
                        opacity.append(presentation.opacity); scales.append(presentation.transform.m11)
                        glow.append(presentation.shadowOpacity); spread.append(presentation.shadowRadius)
                    }
                    if light.animation(forKey: "qiming.breathe")?.beginTime != beginTime {
                        failures.append("metadata refresh restarted pulse: \(mode)")
                    }
                }
                if opacity.count != 7 || (opacity.max() ?? 0) - (opacity.min() ?? 0) < 0.15 {
                    failures.append("status light has no visible opacity breathing: \(mode), \(opacity)")
                }
                if (scales.max() ?? 0) - (scales.min() ?? 0) < 0.10 {
                    failures.append("status light has no scale breathing: \(mode), \(scales)")
                }
                if (glow.max() ?? 0) - (glow.min() ?? 0) < 0.20 || (spread.max() ?? 0) - (spread.min() ?? 0) < 1 {
                    failures.append("solid light halo does not breathe: \(mode)")
                }
                status.setPresented(false)
                if light.animation(forKey: "qiming.breathe") != nil { failures.append("hidden pulse did not stop") }
                print("CHECK live solid pulse \(mode): opacity=\(opacity), scale=\(scales), glow=\(glow), radius=\(spread); metadata does not reset cycle")
            }
        }
        pulsePopover.performClose(nil)

        var transitions = 0
        for language in [Language.chinese, .english] {
            Localization.language = language
            for variant in GlassAppearanceVariant.allCases {
                for from in DisplayMode.allCases {
                    for to in DisplayMode.allCases where to != from {
                        let model = AppModel(); model.glassAppearance = variant; model.stage(from)
                        let controller = PanelController(model: model)
                        let popover = GlassPopover(); popover.animates = false
                        popover.contentViewController = controller
                        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
                        let window = controller.view.window!
                        let originalTop = window.frame.maxY
                        let originalRows = modeRows(in: controller.view)
                        let originalLight = indicator(in: controller.view)
                        let originalPicker = durationPopup(in: controller.view)
                        let originalOff = buttons(in: controller.view).first { $0.identifier?.rawValue == "qiming.screenOff" }
                        let originalFooter = originalOff?.superview
                        var frameSamples = 0
                        let observer = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification,
                            object: window, queue: .main) { _ in
                                MainActor.assumeIsolated {
                                    if window.isVisible && abs(window.frame.maxY - originalTop) > 0.5 {
                                        failures.append("top edge moved during \(from)->\(to): \(window.frame)")
                                    }
                                    frameSamples += 1
                                }
                            }
                        controller.choose(to)
                        // The helper is ready. No setup card may occur, even before the async start begins.
                        if texts(in: controller.view).contains(L("setup.title")) {
                            failures.append("transient setup card \(language)/\(variant): \(from)->\(to)")
                        }
                        if to == .always {
                            // Keep the required confirmation visible long enough to exercise
                            // its real expand/collapse, rather than skipping its layout turn.
                            try? await Task.sleep(for: .milliseconds(40))
                            guard let proceed = buttons(in: controller.view).first(where: { $0.title == L("risk.enable") }) else {
                                failures.append("missing explicit Always On confirmation"); continue
                            }
                            proceed.actionBlock?()
                        }
                        for _ in 0..<50 {
                            if model.mode == to && !model.busy { break }
                            try? await Task.sleep(for: .milliseconds(20))
                        }
                        // Frame changes are coalesced onto the next main-loop turn.
                        try? await Task.sleep(for: .milliseconds(20))
                        if model.mode != to { failures.append("mode did not complete: \(from)->\(to); actual=\(model.mode), busy=\(model.busy)") }
                        let currentRows = modeRows(in: controller.view)
                        if zip(originalRows, currentRows).contains(where: { $0 !== $1 })
                            || indicator(in: controller.view) !== originalLight {
                            failures.append("strategy switch recreated native policy glass or header: \(from)->\(to)")
                        }
                        let currentOff = buttons(in: controller.view).first { $0.identifier?.rawValue == "qiming.screenOff" }
                        if durationPopup(in: controller.view) !== originalPicker || currentOff !== originalOff
                            || currentOff?.superview !== originalFooter {
                            failures.append("policy switch recreated the footer controls or glass: \(from)->\(to)")
                        }
                        let systemControl = currentRows.first(where: { $0.mode == .system })?.selector
                        if systemControl?.isEnabled != (to != .system) {
                            failures.append("Follow System switch should only be enabled while another policy is selected")
                        }
                        let selectedRows = modeRows(in: controller.view).filter { $0.selector.state == .on }
                        if selectedRows.count != 1 || selectedRows.first?.mode != to {
                            failures.append("right-side switches lost policy exclusivity: \(from)->\(to)")
                        }
                        controller.view.layoutSubtreeIfNeeded()
                        for row in modeRows(in: controller.view) {
                            let switchRect = row.selector.convert(row.selector.bounds, to: controller.view)
                            if let popup = durationPopup(in: controller.view) {
                                let popupRect = popup.convert(popup.bounds, to: controller.view)
                                if abs(switchRect.maxX - popupRect.maxX) > 0.5 { failures.append("switch and duration trailing edges differ") }
                            }
                            if switchRect.width > 42.5 { failures.append("native switch was not reduced") }
                            for label in row.subviews.flatMap({ $0.subviews }).compactMap({ $0 as? NSTextField }) {
                                let needed = label.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: label.bounds.width, height: 1000)).height ?? 0
                                if label.bounds.height + 1 < needed {
                                    failures.append("policy text clipped beside native switch: \(language)/\(variant), \(row.mode), \(label.bounds.height)<\(needed)")
                                }
                            }
                        }
                        let controls = buttons(in: controller.view)
                        if let off = controls.first(where: { $0.identifier?.rawValue == "qiming.screenOff" }),
                           let row = modeRows(in: controller.view).first {
                            let grid = row.convert(row.bounds, to: controller.view)
                            let offFrame = off.convert(off.bounds, to: controller.view)
                            if abs(grid.minX - offFrame.minX) > 0.5 || abs(grid.maxX - offFrame.maxX) > 0.5 {
                                failures.append("footer left/right edges differ from policy grid")
                            }
                            if controls.contains(where: { $0.title == L("view.status") || $0.title == L("stop") }) {
                                failures.append("duplicate footer status/stop actions remain")
                            }
                        } else { failures.append("missing compact footer controls") }
                        if from == .system && to == .closed && frameSamples != 0 {
                            failures.append("unnecessary resize in system->closed: \(frameSamples)")
                        }
                        if to == .always && frameSamples != 2 {
                            failures.append("confirmation should expand/collapse once: \(from)->\(to), events=\(frameSamples)")
                        }
                        if abs(window.frame.maxY - originalTop) > 0.5 { failures.append("final panel top moved: \(from)->\(to)") }
                        NotificationCenter.default.removeObserver(observer)
                        popover.performClose(nil)
                        transitions += 1
                        print("CHECK \(language.rawValue)/\(variant.rawValue) \(from.rawValue)->\(to.rawValue); resize events=\(frameSamples)")
                    }
                }
            }
        }
        let cancelModel = AppModel(); cancelModel.stage(.closed)
        let cancelPanel = PanelController(model: cancelModel)
        let cancelPopover = GlassPopover(); cancelPopover.animates = false
        cancelPopover.contentViewController = cancelPanel
        cancelPopover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        cancelPanel.choose(.always)
        cancelPanel.choose(.closed)
        if texts(in: cancelPanel.view).contains(L("risk.title")) || cancelModel.mode != .closed {
            failures.append("current policy failed to cancel pending confirmation")
        }
        cancelModel.helper.ready = false
        cancelModel.stage(.system)
        cancelPanel.choose(.closed)
        if !texts(in: cancelPanel.view).contains(L("setup.title")) {
            failures.append("missing-helper setup confirmation was lost")
        }
        cancelPopover.performClose(nil)

        let powerModel = AppModel()
        let powerPanel = PanelController(model: powerModel)
        let powerPopover = GlassPopover(); powerPopover.animates = false
        powerPopover.contentViewController = powerPanel
        powerPopover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        var detailOpens = 0
        var quitRequests = 0
        powerPanel.showStatus = { detailOpens += 1 }
        powerPanel.quit = { quitRequests += 1 }
        func headerButton(_ id: String) -> ActionButton? {
            buttons(in: powerPanel.view).first { $0.identifier?.rawValue == "qiming." + id }
        }
        func pressHeader(_ id: String) {
            guard let button = headerButton(id), button.isEnabled, let action = button.action else {
                failures.append("cannot press header button: \(id)")
                return
            }
            NSApp.sendAction(action, to: button.target, from: button)
        }
        powerPanel.view.layoutSubtreeIfNeeded()
        if let light = indicator(in: powerPanel.view),
           let reset = headerButton("reset"), let quit = headerButton("quit"), let settings = headerButton("settings") {
            let controls: [NSView] = [light, reset, quit, settings]
            let frames = controls.map { control in
                control.superview!.convert(control.alignmentRect(forFrame: control.frame), to: powerPanel.view)
            }
            if frames.map(\.minX) != frames.map(\.minX).sorted()
                || zip(frames, frames.dropFirst()).contains(where: { $0.maxX > $1.minX })
                || frames.contains(where: { $0.width != 26 || $0.height != 26 || abs($0.midY - frames[0].midY) > 0.5 }) {
                failures.append("header controls are out of order, overlapping, or mismatched in size: \(frames)")
            }
            if reset.isEnabled || !quit.isEnabled || reset.image == nil || quit.image == nil {
                failures.append("idle header state or symbols are incorrect")
            }
        } else { failures.append("missing header control") }
        if let light = indicator(in: powerPanel.view), let action = light.action {
            NSApp.sendAction(action, to: light.target, from: light)
        }
        if detailOpens != 1 { failures.append("status light no longer opens details") }
        powerModel.busy = true; powerModel.changed()
        let blockedQuit = headerButton("quit")
        if blockedQuit?.isEnabled != true || blockedQuit?.blocksActions != true || headerButton("reset")?.blocksActions != true {
            failures.append("in-flight header actions must block input without dimming")
        }
        if let blockedQuit, let action = blockedQuit.action { NSApp.sendAction(action, to: blockedQuit.target, from: blockedQuit) }
        if quitRequests != 0 { failures.append("quit accepted input during an in-flight request") }
        if let off = buttons(in: powerPanel.view).first(where: { $0.identifier?.rawValue == "qiming.screenOff" }),
           off.isEnabled != true || !off.blocksActions { failures.append("display action dimmed or accepted input while busy") }
        if durationPopup(in: powerPanel.view)?.isEnabled != true
            || durationPopup(in: powerPanel.view)?.blocksInteraction != true {
            failures.append("duration popup dimmed or accepted input while busy")
        }
        powerModel.busy = false; powerModel.changed()
        powerPanel.choose(.always)
        pressHeader("reset")
        if texts(in: powerPanel.view).contains(L("risk.title")) || !powerModel.starts.isEmpty {
            failures.append("reset failed to cancel pending AlwaysOn confirmation")
        }
        for mode in [DisplayMode.closed, .always, .closed] {
            powerModel.stage(mode)
            if powerModel.stops == 2 { powerModel.status?.phase = "waiting"; powerModel.changed() }
            pressHeader("reset")
            for _ in 0..<25 {
                if powerModel.session == nil && !powerModel.busy { break }
                try? await Task.sleep(for: .milliseconds(10))
            }
            if powerModel.session != nil || powerModel.mode != .system || quitRequests != 0 {
                failures.append("reset failed to return to system without quitting from \(mode)")
            }
        }
        if powerModel.stops != 3 { failures.append("reset did not send all stop requests") }
        powerModel.stage(.closed)
        pressHeader("quit")
        if quitRequests != 1 || powerModel.stops != 3 || !powerModel.starts.isEmpty {
            failures.append("power button did not route to application termination")
        }
        powerPopover.performClose(nil)
        print("CHECK header: status, reset, quit and settings; reset stops active and waiting sessions; power routes to quit")

        let colorModel = AppModel()
        let colorPanel = PanelController(model: colorModel)
        let colorPopover = GlassPopover(); colorPopover.animates = false
        colorPopover.contentViewController = colorPanel
        colorPopover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        func lightColor() -> CGColor? {
            (indicator(in: colorPanel.view)?.layer?.sublayers?.first(where: { $0.name == "qiming.status.light" }) as? CAShapeLayer)?.fillColor
        }
        let idleColor = lightColor()
        colorModel.busy = true; colorModel.changed()
        if lightColor() != idleColor { failures.append("idle start flashed a transitional color") }
        colorModel.stage(.closed)
        if lightColor() != idleColor { failures.append("color changed before request completed") }
        colorModel.busy = false; colorModel.changed()
        let runningColor = lightColor()
        func pulseStart() -> CFTimeInterval? {
            indicator(in: colorPanel.view)?.layer?.sublayers?.first(where: { $0.name == "qiming.status.light" })?
                .animation(forKey: "qiming.breathe")?.beginTime
        }
        let runningPulse = pulseStart()
        if idleColor == nil || runningColor == nil || idleColor == runningColor { failures.append("confirmed start did not change gray to green") }
        colorModel.busy = true; colorModel.changed()
        colorModel.stage(.always)
        if lightColor() != runningColor { failures.append("switch between active policies flashed a transitional color") }
        colorModel.busy = false; colorModel.changed()
        if runningPulse == nil || pulseStart() != runningPulse {
            failures.append("green policy switch restarted the breathing cycle")
        }
        colorModel.busy = true; colorModel.changed()
        colorModel.stage(.system)
        if lightColor() != runningColor { failures.append("stop flashed a transitional color") }
        colorModel.busy = false; colorModel.changed()
        if lightColor() != idleColor { failures.append("confirmed stop did not return to gray") }
        colorModel.stage(.closed); colorModel.status?.phase = "waiting"; colorModel.changed()
        let waitingColor = lightColor()
        if waitingColor == nil || waitingColor == idleColor || waitingColor == runningColor { failures.append("genuine waiting warning lost its color") }
        colorModel.technicalError = "simulated failure"; colorModel.changed()
        if lightColor() == waitingColor { failures.append("failure lost its error color") }
        colorPopover.performClose(nil)
        print("CHECK stable light: gray->green start, green policy switch, green->gray stop; waiting/error colors retained")

        let switchModel = AppModel()
        let switchPanel = PanelController(model: switchModel)
        let switchPopover = GlassPopover(); switchPopover.animates = false
        switchPopover.contentViewController = switchPanel
        switchPopover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        func flip(_ mode: DisplayMode) {
            guard let control = modeRows(in: switchPanel.view).first(where: { $0.mode == mode })?.selector,
                  let action = control.action else { failures.append("missing native mode switch"); return }
            guard control.isEnabled else { return }
            control.state = control.state == .on ? .off : .on
            NSApp.sendAction(action, to: control.target, from: control)
        }
        func selectedSwitches() -> [DisplayMode] {
            modeRows(in: switchPanel.view).filter { $0.selector.state == .on }.map(\.mode)
        }
        switchPanel.view.layoutSubtreeIfNeeded()
        for row in modeRows(in: switchPanel.view) {
            let switchRect = row.selector.convert(row.selector.bounds, to: row)
            if abs(switchRect.maxX - row.bounds.width) > 0.5 || abs(switchRect.midY - row.bounds.midY) > 0.5 {
                failures.append("native switch is not aligned at row's right edge: \(row.mode)")
            }
            if let text = row.subviews.first(where: { $0 is NSStackView }), text.frame.maxX > switchRect.minX - 11 {
                failures.append("policy text overlaps right-side switch: \(row.mode)")
            }
        }
        flip(.system)
        if selectedSwitches() != [.system] { failures.append("Follow System switch left all policies off") }
        flip(.closed)
        if selectedSwitches() != [.system] { failures.append("switch displayed unconfirmed active policy") }
        try? await Task.sleep(for: .milliseconds(100))
        if switchModel.mode != .closed || selectedSwitches() != [.closed] { failures.append("native switch failed to select policy 2 exclusively") }
        flip(.closed)
        try? await Task.sleep(for: .milliseconds(100))
        if switchModel.mode != .system || selectedSwitches() != [.system] { failures.append("turning policy 2 off did not restore Follow System") }
        flip(.always)
        if !texts(in: switchPanel.view).contains(L("risk.title")) || selectedSwitches() != [.system] || switchModel.starts.contains(.always) {
            failures.append("AlwaysOn switch bypassed risk confirmation or showed unconfirmed state")
        }
        buttons(in: switchPanel.view).first(where: { $0.identifier?.rawValue == "qiming.reset" })?.actionBlock?()
        if texts(in: switchPanel.view).contains(L("risk.title")) { failures.append("current policy switch failed to cancel pending risk") }
        switchModel.helper.ready = false
        flip(.closed)
        if !texts(in: switchPanel.view).contains(L("setup.title")) || selectedSwitches() != [.system] { failures.append("native switch bypassed required setup") }
        switchModel.busy = true; switchModel.changed()
        if modeRows(in: switchPanel.view).contains(where: { $0.acceptsSelection }) { failures.append("native policy switches accept input during request") }
        switchPopover.performClose(nil)
        print("CHECK native right switches: aligned, exclusive, confirmed state, off restores system, risk/setup retained, busy input blocked")

        for language in [Language.chinese, .english] {
            Localization.language = language
            let input = PanelCustomDurationInput()
            input.field.stringValue = "90"
            if !texts(in: input).contains(L("duration.minutes")) { failures.append("custom duration unit disappeared with a non-empty value") }
            let popup = PanelDurationPopup(frame: .zero, pullsDown: false)
            popup.font = .systemFont(ofSize: 13)
            popup.addItems(withTitles: ["duration.forever", "duration.30m", "duration.custom"].map(L))
            var widths: [CGFloat] = []
            for index in 0..<3 {
                popup.selectItem(at: index)
                let width = popup.intrinsicContentSize.width
                let ink = (popup.title as NSString).size(withAttributes: [.font: popup.font!]).width
                if width < ink + 30 || width > max(80, ceil(ink) + 40) { failures.append("duration popup is clipped or excessively wide: \(language)") }
                widths.append(width)
            }
            for seconds in [5400.0, 5550.0, 604800.0] {
                let model = AppModel(); model.duration = seconds
                let controller = PanelController(model: model)
                controller.prepareForPresentation()
                let expected = PanelDurationPopup.customTitle(seconds: seconds)
                if durationPopup(in: controller.view)?.title != expected || !expected.contains(L("duration.minutes")) {
                    failures.append("custom duration does not show actual minutes: \(language)/\(seconds)")
                }
                if let item = durationPopup(in: controller.view)?.item(at: 4) {
                    if item.title != L("duration.custom") || (item.attributedTitle != nil && item.attributedTitle?.string != L("duration.custom")) {
                        failures.append("custom duration menu command was replaced by its numeric display")
                    }
                } else { failures.append("missing custom duration menu command") }
            }
            let durationModel = AppModel()
            let durationPanel = PanelController(model: durationModel)
            durationPanel.prepareForPresentation()
            let stablePopup = durationPopup(in: durationPanel.view)
            await durationModel.changePanelDuration(5400)
            durationPanel.prepareForPresentation()
            if stablePopup?.title != PanelDurationPopup.customTitle(seconds: 5400) {
                failures.append("existing popup did not display the custom value")
            }
            await durationModel.changePanelDuration(1800)
            durationPanel.prepareForPresentation()
            if durationPopup(in: durationPanel.view) !== stablePopup || stablePopup?.title != L("duration.30m")
                || stablePopup?.item(at: 4)?.title != L("duration.custom") {
                failures.append("existing popup did not switch from custom value back to preset")
            }
            stablePopup?.selectItem(at: 5) // The native menu selects the command before the date is saved.
            await durationModel.changePanelDuration(1800, until: Date().addingTimeInterval(5400))
            durationModel.glassFontColor = .white
            durationPanel.prepareForPresentation()
            if stablePopup?.title != L("duration.until") || stablePopup?.indexOfSelectedItem != 5 {
                failures.append("scheduled end time lost its display title or selection after changing font color")
            }
            print("CHECK custom duration \(language): 90, 92.5 and 10080 minutes shown instead of generic custom label")
            print("CHECK compact duration \(language): selected-title widths=\(widths); minutes label remains visible")
        }

        let timingModel = AppModel()
        timingModel.glassAppearance = .grayCards
        timingModel.duration = 2700
        timingModel.stage(.closed, deadline: Date().addingTimeInterval(2700))
        let timingPanel = PanelController(model: timingModel)
        timingPanel.prepareForPresentation()
        let timingPopup = durationPopup(in: timingPanel.view)
        let timingRows = sequence(first: timingPopup?.superview, next: { $0?.superview })
            .prefix(while: { $0 != nil })
            .compactMap { $0 as? NSStackView }
            .first { stack in
                stack.arrangedSubviews.count == 3 && stack.arrangedSubviews[1] is NSBox
                    && buttons(in: stack.arrangedSubviews[0]).contains { $0.title == L("duration.extend") }
                    && durationPopup(in: stack.arrangedSubviews[2]) === timingPopup
            }
        if timingRows == nil { failures.append("active timer and duration picker are not grouped in one timing card") }
        timingModel.stage(.closed, deadline: Date().addingTimeInterval(-1))
        timingPanel.prepareForPresentation()
        if !texts(in: timingPanel.view).contains(L("time.ending"))
            || texts(in: timingPanel.view).contains(where: { $0.hasPrefix(L("time.remaining")) }) {
            failures.append("expired countdown stayed at zero instead of showing ending confirmation")
        }
        if durationPopup(in: timingPanel.view) !== timingPopup {
            failures.append("expiry confirmation replaced the duration control")
        }
        if let timingPopup {
            timingPopup.selectItem(at: 0)
            NSApp.sendAction(timingPopup.action!, to: timingPopup.target, from: timingPopup)
            await Task.yield()
        }
        timingPanel.prepareForPresentation()
        if timingModel.session == nil || timingModel.session?.deadline != nil
            || durationPopup(in: timingPanel.view)?.indexOfSelectedItem != 0
            || buttons(in: timingPanel.view).contains(where: { $0.title == L("duration.extend") })
            || texts(in: timingPanel.view).contains(where: { $0.hasPrefix(L("time.remaining")) }) {
            failures.append("manual duration did not clear the active countdown and extension control")
        }
        timingModel.stage(.system)
        timingPanel.prepareForPresentation()
        if durationPopup(in: timingPanel.view) == nil
            || buttons(in: timingPanel.view).contains(where: { $0.title == L("duration.extend") }) {
            failures.append("idle timing card did not reduce to the duration picker")
        }
        print("CHECK timing card: timer and duration share a divider; manual duration clears countdown without stopping")

        let assertionModel = AppModel()
        let assertionPanel = PanelController(model: assertionModel)
        let displayWarning = L("warning.externalDisplay")
        func showsDisplayWarning() -> Bool {
            assertionPanel.prepareForPresentation()
            return texts(in: assertionPanel.view).contains(displayWarning)
        }
        assertionModel.power.lidClosed = true
        assertionModel.stage(.closed)
        assertionModel.externalBlockers = [ExternalSleepBlocker(process: "coreaudiod", kind: .idleSystem)]
        if showsDisplayWarning() { failures.append("system idle assertion produced a display warning") }
        assertionModel.externalBlockers.append(ExternalSleepBlocker(process: "Fixture", kind: .idleDisplay))
        assertionModel.power.lidClosed = false
        if showsDisplayWarning() { failures.append("display assertion warned while the lid was open") }
        assertionModel.power.lidClosed = true
        if !showsDisplayWarning() { failures.append("display assertion did not warn in active closed-lid policy") }
        assertionModel.messageKey = "screen.failed"
        assertionModel.technicalError = "injected failure"
        if showsDisplayWarning() || !texts(in: assertionPanel.view).contains(L("screen.failed"))
            || !buttons(in: assertionPanel.view).contains(where: { $0.title == L("details") }) {
            failures.append("display assertion masked the screen sleep error or its details link")
        }
        print("CHECK external assertions: system-only stays quiet, display warning follows closed-lid policy, errors take precedence")

        // Exercise production optical bounds independently of policy/power state.
        func focusViews(in view: NSView) -> [GlassBackdropFocusView] {
            if let focus = view as? GlassBackdropFocusView { return [focus] }
            return view.subviews.flatMap { focusViews(in: $0) }
        }
        var opticalCases = 0
        if #available(macOS 26.0, *) {
            for variant in GlassAppearanceVariant.allCases {
                for size in [NSSize(width: 352, height: 450), NSSize(width: 466, height: 130)] {
                    let foreground = NSView()
                    let glass = GlassSurfaceView(content: foreground, cornerRadius: 28, backgroundBlendingMode: .withinWindow)
                    glass.variant = variant
                    let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: 900, y: 200), size: size),
                        styleMask: .borderless, backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false
                    window.contentView = glass; window.orderFront(nil)
                    for transparency in [0.0, 0.25, 0.5, 0.75, 1.0] {
                        glass.transparency = transparency; glass.layoutSubtreeIfNeeded()
                        guard let focus = focusViews(in: glass).first else {
                            failures.append("missing full-bleed focus pass"); continue
                        }
                        let sample = focus.convert(focus.bounds, to: glass)
                        let padding = GlassBackdropFocusView.samplingPadding
                        if abs(sample.minX + padding) > 0.5 || abs(sample.maxX - size.width - padding) > 0.5
                            || abs(sample.minY + padding) > 0.5 || abs(sample.maxY - size.height - padding) > 0.5 {
                            failures.append("blur input does not cover all four edges")
                        }
                        if padding < GlassConfiguration.defocusRadius(for: 0) + 1 { failures.append("blur kernel exceeds sampling padding") }
                        if focus.layer?.masksToBounds != true { failures.append("backdrop filter escaped its own bounds") }
                        if let mask = focus.layer?.mask as? CAShapeLayer, let path = mask.path {
                            let visible = focus.convert(path.boundingBoxOfPath, to: glass)
                            let pixel = 1 / window.backingScaleFactor
                            let expected = glass.bounds.insetBy(dx: pixel, dy: pixel)
                            if abs(visible.minX - expected.minX) > 0.1 || abs(visible.maxX - expected.maxX) > 0.1
                                || abs(visible.minY - expected.minY) > 0.1 || abs(visible.maxY - expected.maxY) > 0.1 {
                                failures.append("visible glass edge has a gap larger than its native one-pixel highlight")
                            }
                        } else { failures.append("missing rounded output crop") }
                        let filters = focus.backgroundFilters ?? []
                        let expectedRadius = (GlassConfiguration.defocusRadius(for: transparency) * 20).rounded() / 20
                        if expectedRadius > 0 {
                            let actual = (filters.first?.value(forKey: kCIInputRadiusKey) as? NSNumber)?.doubleValue
                            if actual == nil || abs((actual ?? -1) - expectedRadius) > 0.001 {
                                failures.append("optical slider radius mismatch: expected \(expectedRadius), actual \(String(describing: actual))")
                            }
                        } else if filters.count != 1 { failures.append("clear endpoint retains a blur filter") }
                        if !(foreground.backgroundFilters ?? []).isEmpty || !(foreground.contentFilters ?? []).isEmpty {
                            failures.append("foreground entered the optical filter chain")
                        }
                        opticalCases += 1
                    }
                    window.orderOut(nil)
                }
            }
        }
        print("CHECK optical edges: \(opticalCases) cases; all four input margins, one-pixel output edge, radius changes, foreground untouched")

        let motionModel = AppModel()
        let motionPanel = PanelController(model: motionModel)
        let motionPopover = GlassPopover()
        motionPopover.contentViewController = motionPanel
        motionPopover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        let motionWindow = motionPanel.view.window!
        var openingAlpha = motionWindow.alphaValue
        // Wait for a presented animation frame; a loaded WindowServer can keep the
        // initial alpha at zero beyond a single fixed 50ms sample.
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(10))
            openingAlpha = motionWindow.alphaValue
            if openingAlpha > 0.01 && openingAlpha < 0.99 { break }
        }
        try? await Task.sleep(for: .milliseconds(210))
        if !motionPopover.isShown || !motionWindow.isVisible || abs(motionWindow.alphaValue - 1) > 0.02 {
            failures.append("animated opening did not settle visible: shown=\(motionPopover.isShown), visible=\(motionWindow.isVisible), key=\(motionWindow.isKeyWindow), alpha=\(motionWindow.alphaValue), active=\(app.isActive)")
        }
        // Reproduce AppKit's ordering: resign notification occurs before the
        // status button action on the same event dispatch, not on a later click.
        motionPopover.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: motionWindow))
        if !motionPopover.isShown { failures.append("resign consumed open state before status click") }
        if motionPopover.isShown { motionPopover.performClose(nil) }
        else { motionPopover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY) }
        try? await Task.sleep(for: .milliseconds(240))
        if motionPopover.isShown || motionWindow.isVisible { failures.append("resign-then-toggle reopened the panel") }
        motionPopover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        try? await Task.sleep(for: .milliseconds(240))
        print("CHECK same-event resign -> left toggle: stays closed after fade completion")
        motionPopover.performClose(nil)
        if motionPopover.isShown { failures.append("closing must immediately report hidden intent") }
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion && !motionWindow.isVisible {
            failures.append("closing skipped its fade-out")
        }
        try? await Task.sleep(for: .milliseconds(45))
        let closingAlpha = motionWindow.alphaValue
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            if openingAlpha <= 0 || openingAlpha >= 1 || closingAlpha <= 0 || closingAlpha >= 1 {
                failures.append("native window fade has no intermediate alpha: open=\(openingAlpha), close=\(closingAlpha)")
            }
        }
        // A second close must not interrupt the fade, nor may its completion
        // hide a new opening triggered by a rapid next click.
        motionPopover.performClose(nil)
        motionPopover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        try? await Task.sleep(for: .milliseconds(280))
        if !motionPopover.isShown || !motionWindow.isVisible { failures.append("stale close hid a reopened panel") }
        let top = motionWindow.frame.maxY
        motionPanel.choose(.always)
        var topSamples: [CGFloat] = []
        for _ in 0..<8 {
            try? await Task.sleep(for: .milliseconds(35))
            topSamples.append(motionWindow.frame.maxY)
        }
        if topSamples.contains(where: { abs($0 - top) > 0.6 }) { failures.append("animated resize moved top anchor: \(topSamples)") }
        motionPopover.performClose(nil)
        try? await Task.sleep(for: .milliseconds(240))
        if motionWindow.isVisible || motionPopover.isShown { failures.append("animated closing failed to order out") }
        print("CHECK motion: fade open/close alpha=\(openingAlpha)/\(closingAlpha), immediate logical toggle, rapid close/reopen, anchored animated resize=\(topSamples)")
        for failure in failures { print("FAIL \(failure)") }
        print("\(failures.isEmpty ? "PASS" : "DIAGNOSTIC"): \(transitions) transitions; \(failures.count) presentation failures; all power operations simulated")
        if expectFixed && !failures.isEmpty { exit(1) }
    }
}
