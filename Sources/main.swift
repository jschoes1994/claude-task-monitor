import AppKit
import SwiftUI
import Darwin
import Combine

// MARK: - Model

enum SessionStatus: Int, Comparable {
    case needsInput = 0   // idle, last assistant message ended on a tool call → likely waiting for approval/input
    case working = 1      // transcript file written to in the last few seconds
    case done = 2         // idle, last assistant message was plain text → turn finished

    static func < (lhs: SessionStatus, rhs: SessionStatus) -> Bool { lhs.rawValue < rhs.rawValue }

    var label: String {
        switch self {
        case .working: return "Working…"
        case .needsInput: return "Needs input"
        case .done: return "Done"
        }
    }

    var color: Color {
        switch self {
        case .working: return .blue
        case .needsInput: return .orange
        case .done: return .green
        }
    }
}

enum SessionKind {
    case code    // Claude Code session (desktop tab or terminal)
    case cowork  // Claude Cowork agent session
}

struct SessionInfo: Identifiable {
    let id: String          // transcript file path
    let kind: SessionKind
    let sessionId: String
    let name: String        // tab name from ~/.claude/sessions, falling back to project folder
    let lastMessage: String // snippet of the most recent assistant text
    let status: SessionStatus
    let lastActivity: Date
    let livePid: pid_t?     // pid of the running claude process, if any
    let entrypoint: String? // "claude-desktop" when hosted in a Claude Desktop tab
    let desktopId: String?  // Claude Desktop's own session id, for tab-focus deep links
    var agentCount: Int = 0 // background subagents still running (from hook markers)
}

// MARK: - Live session registry (~/.claude/sessions/<pid>.json → tab names)

struct LiveSession {
    let pid: pid_t
    let name: String?
    let entrypoint: String?
}

func loadLiveSessions() -> [String: LiveSession] {
    let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/sessions")
    var map: [String: LiveSession] = [:]
    let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
    for file in files where file.pathExtension == "json" {
        guard let data = try? Data(contentsOf: file),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sessionId = obj["sessionId"] as? String,
              let pid = obj["pid"] as? Int else { continue }
        guard kill(pid_t(pid), 0) == 0 else { continue }  // skip stale entries for dead processes
        map[sessionId] = LiveSession(pid: pid_t(pid),
                                     name: obj["name"] as? String,
                                     entrypoint: obj["entrypoint"] as? String)
    }
    return map
}

// MARK: - Desktop session metadata (~/Library/Application Support/Claude/claude-code-sessions)

/// Claude Desktop stores each tab's visible title and its own session id in per-session
/// metadata files, keyed by `cliSessionId`. Untitled entries are duplicates created by
/// resume-imports, so a titled entry always wins; ties break on most recent activity.
struct DesktopSession {
    let desktopId: String
    let title: String?
    let activity: Double
}

func loadDesktopSessions() -> [String: DesktopSession] {
    let root = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Claude/claude-code-sessions")
    var best: [String: DesktopSession] = [:]
    guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [:] }
    for case let file as URL in enumerator where file.pathExtension == "json" {
        guard let data = try? Data(contentsOf: file),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cliId = obj["cliSessionId"] as? String,
              let desktopId = obj["sessionId"] as? String else { continue }
        if obj["isArchived"] as? Bool == true { continue }
        let title = (obj["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let activity = (obj["lastActivityAt"] as? Double) ?? 0
        let candidate = DesktopSession(desktopId: desktopId, title: title, activity: activity)
        if let existing = best[cliId] {
            let existingRank = (existing.title != nil ? 1 : 0, existing.activity)
            let candidateRank = (candidate.title != nil ? 1 : 0, candidate.activity)
            if candidateRank <= existingRank { continue }
        }
        best[cliId] = candidate
    }
    return best
}

// MARK: - Hook installer (self-contained, works on any machine)

/// Installs/removes the optional status hooks that give exact session states.
/// Everything is derived from the current user's home directory — nothing machine-specific.
enum HookInstaller {
    static let marker = "task-monitor-hook.sh"
    static let events = ["UserPromptSubmit", "PreToolUse", "PermissionRequest", "Notification", "Stop",
                         "SubagentStart", "SubagentStop", "SessionEnd"]

    static var claudeDir: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude") }
    static var scriptURL: URL { claudeDir.appendingPathComponent(marker) }
    static var settingsURL: URL { claudeDir.appendingPathComponent("settings.json") }

    static let scriptBody = """
    #!/bin/bash
    # Claude Task Monitor: records precise session status from Claude Code hook events.
    # Writes ~/.claude/task-monitor/<session_id>.json plus one marker file per running
    # subagent in ~/.claude/task-monitor/<session_id>.agents/
    DIR="$HOME/.claude/task-monitor"
    mkdir -p "$DIR"
    /usr/bin/python3 -c '
    import json, sys, time, os, glob
    try:
        d = json.load(sys.stdin)
    except Exception:
        sys.exit(0)
    sid = d.get("session_id")
    ev = d.get("hook_event_name", "")
    if not sid:
        sys.exit(0)
    base = os.path.join(os.environ["HOME"], ".claude", "task-monitor")
    agents_dir = os.path.join(base, sid + ".agents")

    if ev in ("SubagentStart", "SubagentStop"):
        aid = d.get("agent_id") or d.get("subagent_id") or d.get("task_id") or d.get("tool_use_id")
        if aid is None:
            # unknown payload shape — dump it so the id field can be identified
            with open(os.path.join(base, "debug-" + ev + ".json"), "w") as f:
                json.dump(d, f)
        else:
            aid = str(aid).replace("/", "_")
            if ev == "SubagentStart":
                os.makedirs(agents_dir, exist_ok=True)
                open(os.path.join(agents_dir, aid), "w").close()
            else:
                try: os.remove(os.path.join(agents_dir, aid))
                except FileNotFoundError: pass
        sys.exit(0)

    if ev == "SessionEnd":
        for p in glob.glob(os.path.join(agents_dir, "*")):
            try: os.remove(p)
            except OSError: pass
        state = "done"
    else:
        state = {
            "UserPromptSubmit": "working",
            "PreToolUse": "working",
            "PermissionRequest": "needs_input",
            "Notification": "needs_input",
            "Stop": "done",
        }.get(ev)
    if state:
        path = os.path.join(base, sid + ".json")
        tmp = path + ".tmp"
        with open(tmp, "w") as f:
            json.dump({"state": state, "event": ev, "ts": time.time()}, f)
        os.replace(tmp, path)
    '
    exit 0
    """

    static var isInstalled: Bool {
        guard FileManager.default.fileExists(atPath: scriptURL.path),
              let data = try? Data(contentsOf: settingsURL),
              let text = String(data: data, encoding: .utf8) else { return false }
        return text.contains(marker)
    }

    static func install() throws {
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        try scriptBody.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: settingsURL) {
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw NSError(domain: "HookInstaller", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "~/.claude/settings.json exists but is not valid JSON — fix it manually first."])
            }
            root = obj
        }
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for event in events {
            var entries = hooks[event] as? [[String: Any]] ?? []
            let present = entries.contains { entry in
                ((entry["hooks"] as? [[String: Any]]) ?? []).contains {
                    ($0["command"] as? String)?.contains(marker) == true
                }
            }
            if !present {
                entries.append(["hooks": [["type": "command",
                                           "command": "~/.claude/task-monitor-hook.sh",
                                           "async": true]]])
            }
            hooks[event] = entries
        }
        root["hooks"] = hooks
        let out = try JSONSerialization.data(withJSONObject: root,
                                             options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try out.write(to: settingsURL, options: .atomic)
    }

    static func uninstall() throws {
        if let data = try? Data(contentsOf: settingsURL),
           var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           var hooks = root["hooks"] as? [String: Any] {
            for event in events {
                guard var entries = hooks[event] as? [[String: Any]] else { continue }
                entries.removeAll { entry in
                    let inner = (entry["hooks"] as? [[String: Any]]) ?? []
                    return !inner.isEmpty && inner.allSatisfy {
                        ($0["command"] as? String)?.contains(marker) == true
                    }
                }
                if entries.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = entries }
            }
            if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }
            let out = try JSONSerialization.data(withJSONObject: root,
                                                 options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try out.write(to: settingsURL, options: .atomic)
        }
        try? FileManager.default.removeItem(at: scriptURL)
        try? FileManager.default.removeItem(at: claudeDir.appendingPathComponent("task-monitor"))
    }
}

// MARK: - Opening a session on click

enum SessionOpener {
    static func open(_ session: SessionInfo) {
        // Terminal-hosted session: bring its terminal app to the front and,
        // for Terminal.app/iTerm2, select the exact tab via the session's tty.
        if let pid = session.livePid, session.entrypoint != "claude-desktop",
           let app = hostGUIApp(of: pid) {
            if #available(macOS 14.0, *) {
                NSApp.yieldActivation(to: app)
                app.activate()
            } else {
                app.activate(options: [.activateIgnoringOtherApps])
            }
            if let tty = ttyPath(of: pid) {
                selectTerminalTab(app: app, tty: tty)
            }
            return
        }
        // Known Claude Desktop session: navigate to the tab that's already open.
        // (claude://resume would import a duplicate chat instead.)
        if let desktopId = session.desktopId {
            let route = session.kind == .cowork ? "local_sessions" : "claude-code-desktop"
            if let url = URL(string: "claude://claude.ai/\(route)/\(desktopId)") {
                NSWorkspace.shared.open(url)
            }
            return
        }
        // Unknown to the desktop app: resume imports the CLI transcript as a new desktop session.
        if let url = URL(string: "claude://resume?session=\(session.sessionId)") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Walk the process ancestry until we hit a regular GUI application (Terminal, iTerm, VS Code, …).
    private static func hostGUIApp(of pid: pid_t) -> NSRunningApplication? {
        var appsByPid: [pid_t: NSRunningApplication] = [:]
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            appsByPid[app.processIdentifier] = app
        }
        var current = pid
        for _ in 0..<20 {
            if let app = appsByPid[current] { return app }
            guard let parent = parentPID(of: current), parent > 1 else { return nil }
            current = parent
        }
        return nil
    }

    /// Controlling terminal of the claude process, e.g. "/dev/ttys012".
    private static func ttyPath(of pid: pid_t) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-o", "tty=", "-p", String(pid)]
        let pipe = Pipe()
        p.standardOutput = pipe
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        guard let data = try? pipe.fileHandleForReading.readToEnd(),
              let tty = String(data: data, encoding: .utf8)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !tty.isEmpty, tty != "??" else { return nil }
        return "/dev/" + tty
    }

    /// Best effort: focus the exact tab hosting the session. First use prompts the user
    /// for Automation permission; failures fall back silently to plain app activation.
    private static func selectTerminalTab(app: NSRunningApplication, tty: String) {
        let script: String
        switch app.bundleIdentifier {
        case "com.apple.Terminal":
            script = """
            tell application "Terminal"
                repeat with w in windows
                    repeat with t in tabs of w
                        if tty of t is "\(tty)" then
                            set selected tab of w to t
                            set index of w to 1
                            return
                        end if
                    end repeat
                end repeat
            end tell
            """
        case "com.googlecode.iterm2":
            script = """
            tell application "iTerm2"
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            if tty of s is "\(tty)" then
                                select w
                                select t
                                select s
                                return
                            end if
                        end repeat
                    end repeat
                end repeat
            end tell
            """
        default:
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            var error: NSDictionary?
            NSAppleScript(source: script)?.executeAndReturnError(&error)
        }
    }

    private static func parentPID(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }
}

// MARK: - AI titles for terminal sessions

/// Generates short session titles from the first prompt using the user's own
/// `claude` CLI (Haiku, print mode, no transcript). Results are cached forever;
/// failures (e.g. expired CLI login) fall back silently to the raw first prompt.
final class AITitles {
    static let shared = AITitles()
    private var cache: [String: String] =
        (UserDefaults.standard.dictionary(forKey: "aiTitles") as? [String: String]) ?? [:]
    private var inFlight = Set<String>()
    private var failed = Set<String>()          // per-run; retried on next launch
    private let queue = DispatchQueue(label: "ai-titles")   // one generation at a time
    private let lock = NSLock()
    private lazy var binary: String? = resolveClaudeBinary()

    /// Cached title, or nil (and kicks off background generation) if not ready.
    func title(for sessionId: String, firstPrompt: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        if let t = cache[sessionId] { return t }
        guard !inFlight.contains(sessionId), !failed.contains(sessionId),
              firstPrompt.count > 12, !firstPrompt.hasPrefix("Session ") else { return nil }
        inFlight.insert(sessionId)
        queue.async { [weak self] in self?.generate(sessionId: sessionId, prompt: firstPrompt) }
        return nil
    }

    private func generate(sessionId: String, prompt: String) {
        defer { lock.lock(); inFlight.remove(sessionId); lock.unlock() }
        guard let bin = binary else { markFailed(sessionId); return }

        let instruction = "Generate a concise 3-6 word title for a coding session that started "
            + "with this request. Reply with only the title, no quotes or punctuation:\n\n"
            + prompt.prefix(500)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = ["-p", "--model", "haiku", "--no-session-persistence",
                       "--settings", #"{"disableAllHooks":true}"#]
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { markFailed(sessionId); return }
        inPipe.fileHandleForWriting.write(Data(instruction.utf8))
        try? inPipe.fileHandleForWriting.close()

        let deadline = Date().addingTimeInterval(60)
        while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.5) }
        if p.isRunning { p.terminate(); markFailed(sessionId); return }

        let data = (try? outPipe.fileHandleForReading.readToEnd()) ?? Data()
        var title = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        title = title.replacingOccurrences(of: "\"", with: "")
        if let firstLine = title.split(separator: "\n").first { title = String(firstLine) }
        guard p.terminationStatus == 0, !title.isEmpty, title.count <= 80 else {
            markFailed(sessionId); return
        }
        lock.lock()
        cache[sessionId] = title
        UserDefaults.standard.set(cache, forKey: "aiTitles")
        lock.unlock()
    }

    private func markFailed(_ sessionId: String) {
        lock.lock(); failed.insert(sessionId); lock.unlock()
    }

    /// PATH lookup via a login shell (GUI apps get a minimal PATH), then the copy
    /// bundled inside Claude Desktop.
    private func resolveClaudeBinary() -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", "command -v claude"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        if (try? p.run()) != nil {
            p.waitUntilExit()
            if p.terminationStatus == 0,
               let d = try? out.fileHandleForReading.readToEnd(),
               let s = String(data: d, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !s.isEmpty {
                return s
            }
        }
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/claude-code")
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: dir.path) {
            for v in versions.sorted().reversed() {
                let bin = dir.appendingPathComponent("\(v)/claude.app/Contents/MacOS/claude").path
                if FileManager.default.isExecutableFile(atPath: bin) { return bin }
            }
        }
        return nil
    }
}

// MARK: - Transcript scanning

final class SessionMonitor: ObservableObject {
    @Published var sessions: [SessionInfo] = []        // visible feed
    @Published var hiddenSessions: [SessionInfo] = []  // hidden chats, shown on demand
    @Published var showHidden = false

    /// User-adjustable text size (slider in Settings).
    @Published var fontScale: Double = {
        let v = UserDefaults.standard.double(forKey: "fontScale")
        return v == 0 ? 1.0 : v
    }() {
        didSet { UserDefaults.standard.set(fontScale, forKey: "fontScale") }
    }

    /// Which interfaces show the feed. The menu-bar icon always remains so Settings
    /// stays reachable even with both turned off.
    @Published var panelEnabled: Bool =
        UserDefaults.standard.object(forKey: "panelVisible") as? Bool ?? true {
        didSet { UserDefaults.standard.set(panelEnabled, forKey: "panelVisible") }
    }
    @Published var popoverEnabled: Bool =
        UserDefaults.standard.object(forKey: "popoverEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(popoverEnabled, forKey: "popoverEnabled") }
    }

    /// Name terminal sessions with a short AI title generated from their first prompt
    /// (uses the local `claude` CLI with Haiku; one tiny call per session, cached).
    @Published var aiTitlesEnabled: Bool =
        UserDefaults.standard.object(forKey: "aiTitlesEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(aiTitlesEnabled, forKey: "aiTitlesEnabled") }
    }

    // "Done and unseen" badge: when a session flips to done we timestamp it; the badge
    // counts ones newer than the last time the user looked at the feed.
    private var doneSince: [String: Date] = [:]
    private var lastSeen = Date()
    private var seededDone = false

    func markSeen() { lastSeen = Date() }

    func unseenDoneCount() -> Int {
        sessions.filter { s in
            s.status == .done && (doneSince[s.sessionId].map { $0 > lastSeen } ?? false)
        }.count
    }

    private var allSessions: [SessionInfo] = []
    // sessionId → lastActivity at dismissal; the row reappears on any newer message
    private var dismissed: [String: Double] =
        (UserDefaults.standard.dictionary(forKey: "dismissedSessions") as? [String: Double]) ?? [:]
    // sessionIds hidden until explicitly unhidden
    private var hiddenIds: Set<String> =
        Set(UserDefaults.standard.stringArray(forKey: "hiddenSessions") ?? [])

    func dismiss(_ session: SessionInfo) {
        dismissed[session.sessionId] = session.lastActivity.timeIntervalSince1970
        UserDefaults.standard.set(dismissed, forKey: "dismissedSessions")
        publish()
    }

    func hide(_ session: SessionInfo) {
        hiddenIds.insert(session.sessionId)
        UserDefaults.standard.set(Array(hiddenIds), forKey: "hiddenSessions")
        publish()
    }

    func unhide(_ session: SessionInfo) {
        hiddenIds.remove(session.sessionId)
        UserDefaults.standard.set(Array(hiddenIds), forKey: "hiddenSessions")
        publish()
    }

    private func publish() {
        // Track done-transitions. On the very first publish, pre-existing done sessions
        // are seeded as already seen so the badge doesn't light up at launch.
        for s in allSessions {
            if s.status == .done {
                if doneSince[s.sessionId] == nil {
                    doneSince[s.sessionId] = seededDone ? Date() : .distantPast
                }
            } else {
                doneSince.removeValue(forKey: s.sessionId)
            }
        }
        seededDone = true

        sessions = allSessions.filter { s in
            guard !hiddenIds.contains(s.sessionId) else { return false }
            if let at = dismissed[s.sessionId] {
                return s.lastActivity.timeIntervalSince1970 > at + 1  // reappear on new activity
            }
            return true
        }
        hiddenSessions = allSessions.filter { hiddenIds.contains($0.sessionId) }
    }

    private var timer: Timer?
    private let projectsDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/projects")
    private var firstMessageCache: [String: String] = [:]

    // Sessions idle longer than this are dropped from the list entirely.
    private let maxAge: TimeInterval = 8 * 60 * 60
    // A file written to within this window counts as actively working.
    private let workingWindow: TimeInterval = 20

    func start() {
        scan()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.scan()
        }
    }

    private func scan() {
        let fm = FileManager.default
        var found: [SessionInfo] = []
        let now = Date()
        let live = loadLiveSessions()
        let desktop = loadDesktopSessions()

        let projectDirs = (try? fm.contentsOfDirectory(at: projectsDir, includingPropertiesForKeys: nil)) ?? []
        for dir in projectDirs {
            let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for file in files {
                guard file.pathExtension == "jsonl",
                      !file.lastPathComponent.hasPrefix("agent-") else { continue }
                guard let mtime = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                      now.timeIntervalSince(mtime) < maxAge else { continue }

                if let info = inspect(file: file, mtime: mtime, now: now, live: live, desktop: desktop) {
                    found.append(info)
                }
            }
        }

        scanCowork(now: now, into: &found)

        found.sort {
            if $0.status != $1.status { return $0.status < $1.status }
            return $0.lastActivity > $1.lastActivity
        }
        let result = Array(found.prefix(30))

        DispatchQueue.main.async {
            self.allSessions = result
            self.publish()
        }
    }

    /// Hook events (installed via ~/.claude/settings.json) give exact status; transcript
    /// heuristics remain the fallback for sessions without hook data (e.g. Cowork sandboxes).
    /// `activity` is the timestamp of the last real message — NOT the file mtime, which
    /// Claude Code also touches for non-conversation entries (draft prompts, mode changes).
    private func resolveStatus(sessionId: String, last: LastEntry, activity: Date, now: Date) -> SessionStatus {
        if last.interrupted { return .done }   // user pressed stop; turn is over

        let age = now.timeIntervalSince(activity)

        let eventFile = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/task-monitor/\(sessionId).json")
        if let data = try? Data(contentsOf: eventFile),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let state = obj["state"] as? String,
           let ts = obj["ts"] as? Double,
           ts >= activity.timeIntervalSince1970 - 5 {  // event at least as fresh as the last message
            switch state {
            case "needs_input": return .needsInput
            case "working": return .working            // long-running tool: no writes, still busy
            case "done": return .done
            default: break
            }
        }

        if age < workingWindow { return .working }     // messages are actively streaming
        if last.role == "assistant" && last.endsWithToolUse { return .needsInput }
        if last.role == "user" && age < 90 { return .working }
        return .done
    }

    /// Background subagents still running, from SubagentStart/Stop hook marker files.
    private func runningAgentCount(sessionId: String, now: Date) -> Int {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/task-monitor/\(sessionId).agents")
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return 0 }
        return files.filter { f in
            guard let m = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            else { return false }
            return now.timeIntervalSince(m) < 4 * 3600   // orphaned markers expire
        }.count
    }

    private func inspect(file: URL, mtime: Date, now: Date, live: [String: LiveSession], desktop: [String: DesktopSession]) -> SessionInfo? {
        guard let last = lastEntry(of: file) else { return nil }

        let sessionId = file.deletingPathExtension().lastPathComponent
        let activity = last.timestamp ?? mtime
        var status = resolveStatus(sessionId: sessionId, last: last, activity: activity, now: now)
        let agents = runningAgentCount(sessionId: sessionId, now: now)
        if agents > 0 && status == .done { status = .working }  // main loop idle, agents busy
        let liveInfo = live[sessionId]
        let desktopInfo = desktop[sessionId]
        let name: String
        if let title = desktopInfo?.title {
            name = title                                   // Claude Desktop tab title
        } else if liveInfo?.entrypoint == "claude-desktop", let tabName = liveInfo?.name {
            name = tabName                                 // desktop tab not yet titled
        } else {
            // Terminal sessions have no meaningful tab name: AI-generated title when
            // available, otherwise the raw first prompt.
            let firstPrompt = firstUserMessage(of: file)
            name = (aiTitlesEnabled ? AITitles.shared.title(for: sessionId, firstPrompt: firstPrompt) : nil)
                ?? firstPrompt
        }
        let lastMessage = last.lastAssistantText ?? firstUserMessage(of: file)

        return SessionInfo(id: file.path, kind: .code, sessionId: sessionId, name: name,
                           lastMessage: lastMessage, status: status, lastActivity: activity,
                           livePid: liveInfo?.pid, entrypoint: liveInfo?.entrypoint,
                           desktopId: desktopInfo?.desktopId, agentCount: agents)
    }

    /// Cowork agent sessions live in their own sandbox, each with a private .claude/projects
    /// tree. Metadata (title, cli session id) sits next to the sandbox directory.
    private func scanCowork(now: Date, into found: inout [SessionInfo]) {
        let fm = FileManager.default
        let root = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/local-agent-mode-sessions")
        guard let orgs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        for org in orgs {
            guard (try? org.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                  let workspaces = try? fm.contentsOfDirectory(at: org, includingPropertiesForKeys: [.isDirectoryKey]) else { continue }
            for workspace in workspaces {
                guard let entries = try? fm.contentsOfDirectory(at: workspace, includingPropertiesForKeys: nil) else { continue }
                for meta in entries where meta.pathExtension == "json" && meta.lastPathComponent.hasPrefix("local_") {
                    guard let data = try? Data(contentsOf: meta),
                          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          obj["isArchived"] as? Bool != true,
                          let desktopId = obj["sessionId"] as? String,
                          let cliId = obj["cliSessionId"] as? String else { continue }
                    let activityMs = (obj["lastActivityAt"] as? Double) ?? 0
                    guard now.timeIntervalSince1970 - activityMs / 1000 < maxAge else { continue }

                    guard let transcript = coworkTranscript(sandbox: workspace.appendingPathComponent(desktopId), cliId: cliId),
                          let mtime = (try? transcript.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                          now.timeIntervalSince(mtime) < maxAge,
                          let last = lastEntry(of: transcript) else { continue }

                    let activity = last.timestamp ?? mtime
                    let status = resolveStatus(sessionId: cliId, last: last, activity: activity, now: now)
                    let title = (obj["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Cowork session"
                    found.append(SessionInfo(
                        id: transcript.path, kind: .cowork, sessionId: cliId, name: title,
                        lastMessage: last.lastAssistantText ?? firstUserMessage(of: transcript),
                        status: status, lastActivity: activity,
                        livePid: nil, entrypoint: nil, desktopId: desktopId))
                }
            }
        }
    }

    private func coworkTranscript(sandbox: URL, cliId: String) -> URL? {
        let projects = sandbox.appendingPathComponent(".claude/projects")
        guard let dirs = try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil) else { return nil }
        for dir in dirs {
            let candidate = dir.appendingPathComponent("\(cliId).jsonl")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    private struct LastEntry {
        var role: String
        var endsWithToolUse: Bool
        var cwd: String?
        var lastAssistantText: String?
        var timestamp: Date?      // when the last real message was written
        var interrupted: Bool = false
    }

    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain = ISO8601DateFormatter()

    private func parseISO(_ s: String?) -> Date? {
        guard let s else { return nil }
        return Self.isoFractional.date(from: s) ?? Self.isoPlain.date(from: s)
    }

    /// Read the tail of the transcript; capture the newest message entry plus the newest assistant text.
    private func lastEntry(of file: URL) -> LastEntry? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let readLen: UInt64 = 131072
        let offset = size > readLen ? size - readLen : 0
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd(),
              let text = String(data: data, encoding: .utf8) else { return nil }

        var entry: LastEntry?
        for line in text.split(separator: "\n").reversed() {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let message = obj["message"] as? [String: Any],
                  let role = message["role"] as? String else { continue }
            if obj["isSidechain"] as? Bool == true { continue }

            let content = message["content"] as? [[String: Any]]
            if entry == nil {
                let toolUse = (content?.last?["type"] as? String) == "tool_use"
                var interrupted = false
                if role == "user" {
                    // Pressing stop/esc appends a user entry marking the interruption
                    let text = (message["content"] as? String)
                        ?? content?.compactMap { $0["text"] as? String }.joined(separator: " ") ?? ""
                    interrupted = text.contains("[Request interrupted")
                }
                entry = LastEntry(role: role, endsWithToolUse: toolUse, cwd: obj["cwd"] as? String,
                                  timestamp: parseISO(obj["timestamp"] as? String),
                                  interrupted: interrupted)
            }
            if entry?.lastAssistantText == nil, role == "assistant",
               let snippet = content?.last(where: { ($0["type"] as? String) == "text" })?["text"] as? String {
                let cleaned = snippet.trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "\n", with: " ")
                if !cleaned.isEmpty {
                    entry?.lastAssistantText = String(cleaned.prefix(140))
                }
            }
            if let e = entry, e.lastAssistantText != nil { return e }
        }
        return entry
    }

    /// First real user message from the head of the file; fallback subtitle for brand-new sessions.
    private func firstUserMessage(of file: URL) -> String {
        if let cached = firstMessageCache[file.path] { return cached }

        var title = "Session \(file.deletingPathExtension().lastPathComponent.prefix(8))"
        if let handle = try? FileHandle(forReadingFrom: file),
           let data = try? handle.read(upToCount: 65536),
           let text = String(data: data, encoding: .utf8) {
            try? handle.close()
            for line in text.split(separator: "\n") {
                guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
                if let summary = obj["summary"] as? String, !summary.isEmpty {
                    title = summary
                    break
                }
                guard obj["isSidechain"] as? Bool != true,
                      let message = obj["message"] as? [String: Any],
                      message["role"] as? String == "user" else { continue }

                var candidate: String?
                if let s = message["content"] as? String {
                    candidate = s
                } else if let items = message["content"] as? [[String: Any]] {
                    candidate = items.first(where: { ($0["type"] as? String) == "text" })?["text"] as? String
                }
                if let c = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !c.isEmpty, !c.hasPrefix("<"), !c.hasPrefix("Caveat:") {
                    title = c.replacingOccurrences(of: "\n", with: " ")
                    break
                }
            }
        }
        title = String(title.prefix(140))
        firstMessageCache[file.path] = title
        return title
    }

}

// MARK: - UI

/// Lets the header's gear button reach the app delegate without plumbing.
enum AppActions {
    static var openSettings: (() -> Void)?
}

struct SettingsView: View {
    @ObservedObject var monitor: SessionMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Text Size")
                .font(.system(size: 12, weight: .semibold))
            HStack(spacing: 10) {
                Text("A").font(.system(size: 10))
                Slider(value: $monitor.fontScale, in: 0.7...1.7)
                Text("A").font(.system(size: 17))
            }

            Divider()

            Text("Interface")
                .font(.system(size: 12, weight: .semibold))
            Toggle("Floating panel (always on top)", isOn: $monitor.panelEnabled)
            Toggle("Menu bar popover (left-click the icon)", isOn: $monitor.popoverEnabled)

            Divider()

            Text("Naming")
                .font(.system(size: 12, weight: .semibold))
            Toggle("AI titles for terminal sessions", isOn: $monitor.aiTitlesEnabled)
            Text("Generates a short title from each terminal session's first prompt using your `claude` CLI (Haiku, one small call per session, cached). Requires the CLI to be logged in — run `claude` in a terminal once if titles don't appear.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !monitor.panelEnabled && !monitor.popoverEnabled {
                Label("Feed hidden everywhere. Badges stay in the menu bar, and left-clicking the icon opens the menu.",
                      systemImage: "info.circle")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(width: 340)
    }
}

struct ContentView: View {
    @ObservedObject var monitor: SessionMonitor
    private var s: CGFloat { CGFloat(monitor.fontScale) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if monitor.sessions.isEmpty && !(monitor.showHidden && !monitor.hiddenSessions.isEmpty) {
                Text("No Claude Code sessions active\nin the last 8 hours")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(monitor.sessions) { session in
                            SessionRow(session: session, monitor: monitor, isHidden: false)
                            Divider().opacity(0.4)
                        }
                        if monitor.showHidden && !monitor.hiddenSessions.isEmpty {
                            HStack {
                                Text("Hidden")
                                    .font(.system(size: 10 * s, weight: .semibold))
                                    .foregroundStyle(.tertiary)
                                Spacer()
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            ForEach(monitor.hiddenSessions) { session in
                                SessionRow(session: session, monitor: monitor, isHidden: true)
                                    .opacity(0.55)
                                Divider().opacity(0.4)
                            }
                        }
                    }
                }
            }
        }
        .frame(minWidth: 300, minHeight: 120)
    }

    private var header: some View {
        HStack(spacing: 8 * s) {
            Text("Claude Tasks")
                .font(.system(size: 12 * s, weight: .semibold))
            Spacer()
            let needing = monitor.sessions.filter { $0.status == .needsInput }.count
            let working = monitor.sessions.filter { $0.status == .working }.count
            if needing > 0 {
                badge("\(needing) waiting", color: .orange)
            }
            if working > 0 {
                badge("\(working) working", color: .blue)
            }
            Button { AppActions.openSettings?() } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 10 * s))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Settings")
            if !monitor.hiddenSessions.isEmpty || monitor.showHidden {
                Button {
                    monitor.showHidden.toggle()
                } label: {
                    Image(systemName: monitor.showHidden ? "eye" : "eye.slash")
                        .font(.system(size: 10 * s))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(monitor.showHidden ? "Conceal hidden chats" : "Show hidden chats (\(monitor.hiddenSessions.count))")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10 * s, weight: .medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }
}

struct SessionRow: View {
    let session: SessionInfo
    let monitor: SessionMonitor
    let isHidden: Bool
    @State private var pulse = false
    @State private var hovering = false
    private var s: CGFloat { CGFloat(monitor.fontScale) }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(session.status.color)
                .frame(width: 9 * s, height: 9 * s)
                .opacity(session.status == .working && pulse ? 0.3 : 1.0)
                .animation(session.status == .working
                           ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
                           : .default, value: pulse)
                .padding(.top, 4)
                .onAppear { pulse = true }
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(session.name)
                        .font(.system(size: 12 * s, weight: .semibold))
                        .lineLimit(1)
                    if session.kind == .cowork {
                        Text("Cowork")
                            .font(.system(size: 9 * s, weight: .medium))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.purple.opacity(0.15), in: Capsule())
                            .foregroundStyle(.purple)
                    }
                    Spacer()
                    if hovering {
                        if isHidden {
                            Button { monitor.unhide(session) } label: {
                                Image(systemName: "eye")
                                    .font(.system(size: 9 * s))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Unhide this chat")
                        } else {
                            Button { monitor.dismiss(session) } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 9 * s, weight: .bold))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Dismiss for now (returns on new activity)")
                        }
                    } else {
                        Text(session.lastActivity, style: .relative)
                            .font(.system(size: 10 * s))
                            .foregroundStyle(.tertiary)
                    }
                }
                Text(session.lastMessage)
                    .font(.system(size: 11 * s))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Text(session.agentCount > 0
                     ? "\(session.status.label) · \(session.agentCount) agent\(session.agentCount == 1 ? "" : "s") running"
                     : session.status.label)
                    .font(.system(size: 10 * s, weight: .medium))
                    .foregroundStyle(session.status.color)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(hovering ? Color.primary.opacity(0.06) : Color.clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { SessionOpener.open(session) }
        .contextMenu {
            Button("Open Session") { SessionOpener.open(session) }
            Divider()
            if isHidden {
                Button("Unhide Chat") { monitor.unhide(session) }
            } else {
                Button("Dismiss for Now") { monitor.dismiss(session) }
                Button("Hide Chat") { monitor.hide(session) }
            }
        }
        .help("Click to open · right-click for options")
    }
}

// MARK: - Floating panel + app lifecycle

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var panel: NSPanel!
    private var statusItem: NSStatusItem!
    private var statusMenu: NSMenu!
    private var hookMenuItem: NSMenuItem!
    private var popover: NSPopover!
    private var settingsWindow: NSWindow?
    private let monitor = SessionMonitor()
    private var badgeTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        monitor.start()

        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 340),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        panel.title = "Claude Tasks"
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.setFrameAutosaveName("ClaudeTasksPanel")

        let hosting = NSHostingView(rootView: ContentView(monitor: monitor))
        panel.contentView = hosting

        if panel.frame.origin == .zero, let screen = NSScreen.main {
            let f = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: f.maxX - 340, y: f.maxY - 380))
        }
        AppActions.openSettings = { [weak self] in self?.openSettings() }

        // Keep the panel in sync with Settings (fires immediately with the saved value).
        monitor.$panelEnabled
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                guard let self else { return }
                if enabled { self.panel.orderFrontRegardless() } else { self.panel.orderOut(nil) }
            }
            .store(in: &cancellables)
        monitor.$popoverEnabled
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                // popover is created in setupStatusItem(), after this first sink fires
                if !enabled, let popover = self?.popover, popover.isShown {
                    popover.performClose(nil)
                }
            }
            .store(in: &cancellables)

        setupStatusItem()
        badgeTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.updateBadge()
        }

        // First launch on a new machine: offer the optional precise-status hooks once.
        if !HookInstaller.isInstalled && !UserDefaults.standard.bool(forKey: "offeredHookInstall") {
            UserDefaults.standard.set(true, forKey: "offeredHookInstall")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.toggleHooks()
            }
        }
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "sparkles.rectangle.stack", accessibilityDescription: "Claude Tasks")
            button.imagePosition = .imageLeft
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        statusMenu = NSMenu()
        statusMenu.delegate = self
        statusMenu.addItem(NSMenuItem(title: "Show/Hide Floating Panel", action: #selector(togglePanel), keyEquivalent: "t"))
        statusMenu.addItem(NSMenuItem(title: "Settings…", action: #selector(openSettingsFromMenu), keyEquivalent: ","))
        statusMenu.addItem(.separator())
        hookMenuItem = NSMenuItem(title: "Enable Precise Status Hooks…", action: #selector(toggleHooks), keyEquivalent: "")
        statusMenu.addItem(hookMenuItem)
        statusMenu.addItem(.separator())
        statusMenu.addItem(NSMenuItem(title: "Quit Claude Task Monitor", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 340, height: 420)
        popover.contentViewController = NSHostingController(rootView: ContentView(monitor: monitor))
    }

    /// Left-click: toggle the feed popover (or the menu when the popover is disabled).
    /// Right-click (or ⌃-click): the options menu.
    @objc private func statusItemClicked() {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) || !monitor.popoverEnabled {
            statusItem.menu = statusMenu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else if let button = statusItem.button {
            monitor.markSeen()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        hookMenuItem.title = HookInstaller.isInstalled
            ? "Disable Precise Status Hooks…"
            : "Enable Precise Status Hooks…"
    }

    @objc private func toggleHooks() {
        let installed = HookInstaller.isInstalled
        let alert = NSAlert()
        if installed {
            alert.messageText = "Remove status hooks?"
            alert.informativeText = "Removes the Task Monitor hook entries from ~/.claude/settings.json and deletes ~/.claude/task-monitor-hook.sh. Your other settings are untouched. The panel keeps working using transcript heuristics."
        } else {
            alert.messageText = "Install status hooks?"
            alert.informativeText = "Writes ~/.claude/task-monitor-hook.sh and adds hook entries to ~/.claude/settings.json so Claude Code reports exact session states (working / needs input / done). Existing settings are preserved, and this is fully reversible from this menu."
        }
        alert.addButton(withTitle: installed ? "Remove" : "Install")
        alert.addButton(withTitle: "Cancel")
        activateSelf()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            if installed { try HookInstaller.uninstall() } else { try HookInstaller.install() }
        } catch {
            let failure = NSAlert()
            failure.messageText = "Couldn't update hooks"
            failure.informativeText = error.localizedDescription
            failure.runModal()
        }
    }

    private func activateSelf() {
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func updateBadge() {
        guard let button = statusItem.button else { return }
        // With the floating panel on screen (or the popover open), everything is
        // already visible — the "done" badge only accumulates in menu-bar-only mode.
        if panel.isVisible || popover.isShown { monitor.markSeen() }

        let needing = monitor.sessions.filter { $0.status == .needsInput }.count
        let unseenDone = monitor.unseenDoneCount()
        let title = NSMutableAttributedString()
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        if needing > 0 {
            title.append(NSAttributedString(string: " ●\(needing)", attributes: [
                .foregroundColor: NSColor.systemOrange, .font: font, .baselineOffset: 1]))
        }
        if unseenDone > 0 {
            title.append(NSAttributedString(string: " ✓\(unseenDone)", attributes: [
                .foregroundColor: NSColor.systemGreen, .font: font, .baselineOffset: 1]))
        }
        button.attributedTitle = title
    }

    @objc private func togglePanel() {
        monitor.panelEnabled.toggle()   // the sink shows/hides the panel and persists
    }

    @objc private func openSettingsFromMenu() { openSettings() }

    private func openSettings() {
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 340, height: 220),
                styleMask: [.titled, .closable],
                backing: .buffered, defer: false
            )
            window.title = "Claude Task Monitor Settings"
            window.contentViewController = NSHostingController(rootView: SettingsView(monitor: monitor))
            window.isReleasedWhenClosed = false
            window.level = .floating   // stay above the panel it configures
            window.center()
            settingsWindow = window
        }
        activateSelf()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}

// Scriptable install/uninstall for automated setups (and CI testing).
let cliArgs = CommandLine.arguments
if cliArgs.contains("--install-hooks") || cliArgs.contains("--uninstall-hooks") {
    do {
        if cliArgs.contains("--uninstall-hooks") {
            try HookInstaller.uninstall()
            print("Task Monitor hooks removed")
        } else {
            try HookInstaller.install()
            print("Task Monitor hooks installed")
        }
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
