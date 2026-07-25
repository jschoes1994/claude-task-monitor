// Claude Task Monitor — Windows port.
// Reads the same Claude Code / Cowork data as the macOS app, from Windows paths:
//   transcripts        %USERPROFILE%\.claude\projects\<proj>\<sessionId>.jsonl
//   hook status        %USERPROFILE%\.claude\task-monitor\<sessionId>.json (+ .agents\ markers)
//   desktop titles     %APPDATA%\Claude\claude-code-sessions\**\local_*.json
//   cowork sandboxes   %APPDATA%\Claude\local-agent-mode-sessions\**
// Click a row -> claude://claude.ai/claude-code-desktop/<id> (or /local_sessions/<id> for Cowork).

using System.Diagnostics;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace ClaudeTaskMonitor;

enum SessionStatus { NeedsInput = 0, Working = 1, Done = 2 }
enum SessionKind { Code, Cowork }

class SessionInfo
{
    public required string SessionId;
    public required SessionKind Kind;
    public required string Name;
    public required string LastMessage;
    public required SessionStatus Status;
    public required DateTime LastActivity;   // UTC
    public string? DesktopId;
    public int AgentCount;
}

static class Paths
{
    public static string Home => Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
    public static string ClaudeDir => Path.Combine(Home, ".claude");
    public static string Projects => Path.Combine(ClaudeDir, "projects");
    public static string TaskMonitor => Path.Combine(ClaudeDir, "task-monitor");
    public static string SettingsJson => Path.Combine(ClaudeDir, "settings.json");
    public static string HookScript => Path.Combine(ClaudeDir, "task-monitor-hook.ps1");
    public static string AppData => Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
    public static string DesktopSessions => Path.Combine(AppData, "Claude", "claude-code-sessions");
    public static string CoworkSessions => Path.Combine(AppData, "Claude", "local-agent-mode-sessions");
}

class DesktopSession
{
    public required string DesktopId;
    public string? Title;
    public double Activity;
}

static class Scanner
{
    const double MaxAgeHours = 8;
    const double WorkingWindowSec = 30;

    public static List<SessionInfo> Scan()
    {
        var now = DateTime.UtcNow;
        var found = new List<SessionInfo>();
        var desktop = LoadDesktopSessions(Paths.DesktopSessions);

        if (Directory.Exists(Paths.Projects))
        {
            foreach (var projDir in SafeDirs(Paths.Projects))
            foreach (var file in SafeFiles(projDir, "*.jsonl"))
            {
                var name = Path.GetFileNameWithoutExtension(file);
                if (name.StartsWith("agent-")) continue;
                var mtime = File.GetLastWriteTimeUtc(file);
                if ((now - mtime).TotalHours > MaxAgeHours) continue;
                var info = Inspect(file, mtime, now, desktop, SessionKind.Code, null);
                if (info != null) found.Add(info);
            }
        }

        ScanCowork(now, found);

        return found
            .OrderBy(s => s.Status)
            .ThenByDescending(s => s.LastActivity)
            .Take(30)
            .ToList();
    }

    static void ScanCowork(DateTime now, List<SessionInfo> found)
    {
        if (!Directory.Exists(Paths.CoworkSessions)) return;
        foreach (var org in SafeDirs(Paths.CoworkSessions))
        foreach (var workspace in SafeDirs(org))
        foreach (var meta in SafeFiles(workspace, "local_*.json"))
        {
            JsonNode? obj;
            try { obj = JsonNode.Parse(File.ReadAllText(meta)); } catch { continue; }
            if (obj?["isArchived"]?.GetValue<bool>() == true) continue;
            var desktopId = obj?["sessionId"]?.GetValue<string>();
            var cliId = obj?["cliSessionId"]?.GetValue<string>();
            if (desktopId == null || cliId == null) continue;
            var activityMs = obj?["lastActivityAt"]?.GetValue<double>() ?? 0;
            if ((now - DateTimeOffset.FromUnixTimeMilliseconds((long)activityMs).UtcDateTime).TotalHours > MaxAgeHours)
                continue;

            var transcript = CoworkTranscript(Path.Combine(workspace, desktopId), cliId);
            if (transcript == null) continue;
            var mtime = File.GetLastWriteTimeUtc(transcript);
            if ((now - mtime).TotalHours > MaxAgeHours) continue;

            var title = obj?["title"]?.GetValue<string>();
            var info = Inspect(transcript, mtime, now, null, SessionKind.Cowork,
                               string.IsNullOrEmpty(title) ? "Cowork session" : title);
            if (info != null)
            {
                info.DesktopId = desktopId;
                found.Add(info);
            }
        }
    }

    static string? CoworkTranscript(string sandbox, string cliId)
    {
        var projects = Path.Combine(sandbox, ".claude", "projects");
        if (!Directory.Exists(projects)) return null;
        foreach (var dir in SafeDirs(projects))
        {
            var candidate = Path.Combine(dir, cliId + ".jsonl");
            if (File.Exists(candidate)) return candidate;
        }
        return null;
    }

    class LastEntry
    {
        public string Role = "";
        public bool EndsWithToolUse;
        public string? LastAssistantText;
        public DateTime? Timestamp;
        public bool Interrupted;
    }

    static SessionInfo? Inspect(string file, DateTime mtime, DateTime now,
                                Dictionary<string, DesktopSession>? desktop,
                                SessionKind kind, string? forcedName)
    {
        var last = ReadLastEntry(file);
        if (last == null) return null;

        var sessionId = Path.GetFileNameWithoutExtension(file);
        var activity = last.Timestamp ?? mtime;
        var status = ResolveStatus(sessionId, last, activity, now);
        var agents = RunningAgentCount(sessionId, now);
        if (agents > 0 && status == SessionStatus.Done) status = SessionStatus.Working;

        var desktopInfo = desktop != null && desktop.TryGetValue(sessionId, out var d) ? d : null;
        var name = forcedName
            ?? desktopInfo?.Title
            ?? FirstUserMessage(file);   // terminal sessions: first prompt reads best

        return new SessionInfo
        {
            SessionId = sessionId,
            Kind = kind,
            Name = name,
            LastMessage = last.LastAssistantText ?? FirstUserMessage(file),
            Status = status,
            LastActivity = activity,
            DesktopId = desktopInfo?.DesktopId,
            AgentCount = agents,
        };
    }

    static SessionStatus ResolveStatus(string sessionId, LastEntry last, DateTime activity, DateTime now)
    {
        if (last.Interrupted) return SessionStatus.Done;
        var age = (now - activity).TotalSeconds;

        // Hook events (precise) — trust when at least as fresh as the last message.
        var eventFile = Path.Combine(Paths.TaskMonitor, sessionId + ".json");
        try
        {
            if (File.Exists(eventFile))
            {
                var obj = JsonNode.Parse(File.ReadAllText(eventFile));
                var state = obj?["state"]?.GetValue<string>();
                var ts = obj?["ts"]?.GetValue<double>() ?? 0;
                var activityEpoch = new DateTimeOffset(activity).ToUnixTimeMilliseconds() / 1000.0;
                if (state != null && ts >= activityEpoch - 5)
                {
                    switch (state)
                    {
                        case "needs_input": return SessionStatus.NeedsInput;
                        case "working": return SessionStatus.Working;
                        case "done": return SessionStatus.Done;
                    }
                }
            }
        }
        catch { }

        if (age < WorkingWindowSec) return SessionStatus.Working;
        if (last.Role == "assistant" && last.EndsWithToolUse) return SessionStatus.NeedsInput;
        if (last.Role == "user" && age < 90) return SessionStatus.Working;
        return SessionStatus.Done;
    }

    static int RunningAgentCount(string sessionId, DateTime now)
    {
        var dir = Path.Combine(Paths.TaskMonitor, sessionId + ".agents");
        if (!Directory.Exists(dir)) return 0;
        try
        {
            return Directory.GetFiles(dir)
                .Count(f => (now - File.GetLastWriteTimeUtc(f)).TotalHours < 4);
        }
        catch { return 0; }
    }

    static LastEntry? ReadLastEntry(string file)
    {
        string tail;
        try
        {
            using var fs = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
            var readLen = (int)Math.Min(fs.Length, 128 * 1024);
            fs.Seek(-readLen, SeekOrigin.End);
            var buf = new byte[readLen];
            fs.ReadExactly(buf);
            tail = Encoding.UTF8.GetString(buf);
        }
        catch { return null; }

        foreach (var line in tail.Split('\n').Reverse())
        {
            if (string.IsNullOrWhiteSpace(line)) continue;
            JsonNode? obj;
            try { obj = JsonNode.Parse(line); } catch { continue; }
            if (obj?["isSidechain"]?.GetValue<bool>() == true) continue;
            var message = obj?["message"];
            var role = message?["role"]?.GetValue<string>();
            if (role != "user" && role != "assistant") continue;

            var entry = new LastEntry { Role = role! };
            if (message?["content"] is JsonArray content)
            {
                entry.EndsWithToolUse = content.Count > 0
                    && content[^1]?["type"]?.GetValue<string>() == "tool_use";
                if (role == "assistant")
                    entry.LastAssistantText = content
                        .Select(c => c?["type"]?.GetValue<string>() == "text" ? c?["text"]?.GetValue<string>() : null)
                        .LastOrDefault(t => !string.IsNullOrEmpty(t));
                if (role == "user")
                    entry.Interrupted = content.Any(c =>
                        (c?["text"]?.GetValue<string>() ?? "").Contains("[Request interrupted"));
            }
            else if (message?["content"] is JsonValue v && role == "user")
            {
                entry.Interrupted = (v.GetValue<string>() ?? "").Contains("[Request interrupted");
            }
            var ts = obj?["timestamp"]?.GetValue<string>();
            if (ts != null && DateTimeOffset.TryParse(ts, out var parsed))
                entry.Timestamp = parsed.UtcDateTime;

            // Walk further back for the newest assistant text if this entry is a user turn.
            if (entry.LastAssistantText == null && role == "user")
            {
                foreach (var l2 in tail.Split('\n').Reverse())
                {
                    try
                    {
                        var o2 = JsonNode.Parse(l2);
                        if (o2?["isSidechain"]?.GetValue<bool>() == true) continue;
                        if (o2?["message"]?["role"]?.GetValue<string>() != "assistant") continue;
                        if (o2?["message"]?["content"] is JsonArray c2)
                        {
                            var text = c2
                                .Select(c => c?["type"]?.GetValue<string>() == "text" ? c?["text"]?.GetValue<string>() : null)
                                .LastOrDefault(t => !string.IsNullOrEmpty(t));
                            if (text != null) { entry.LastAssistantText = text; break; }
                        }
                    }
                    catch { }
                }
            }
            if (entry.LastAssistantText != null)
                entry.LastAssistantText = Squeeze(entry.LastAssistantText, 160);
            return entry;
        }
        return null;
    }

    static readonly Dictionary<string, string> firstPromptCache = new();

    static string FirstUserMessage(string file)
    {
        if (firstPromptCache.TryGetValue(file, out var cached)) return cached;
        var result = "Session " + Path.GetFileNameWithoutExtension(file)[..8];
        try
        {
            using var reader = new StreamReader(file);
            for (int i = 0; i < 200; i++)
            {
                var line = reader.ReadLine();
                if (line == null) break;
                JsonNode? obj;
                try { obj = JsonNode.Parse(line); } catch { continue; }
                if (obj?["isSidechain"]?.GetValue<bool>() == true) continue;
                if (obj?["message"]?["role"]?.GetValue<string>() != "user") continue;
                string? text = null;
                if (obj?["message"]?["content"] is JsonValue v) text = v.GetValue<string>();
                else if (obj?["message"]?["content"] is JsonArray arr)
                    text = arr.Select(c => c?["text"]?.GetValue<string>())
                              .FirstOrDefault(t => !string.IsNullOrEmpty(t));
                if (string.IsNullOrWhiteSpace(text)) continue;
                if (text.StartsWith("<") || text.StartsWith("Caveat:")) continue;
                result = Squeeze(text, 80);
                break;
            }
        }
        catch { }
        firstPromptCache[file] = result;
        return result;
    }

    static string Squeeze(string s, int max)
    {
        s = string.Join(" ", s.Split('\n', '\r', '\t').Where(p => p.Length > 0)).Trim();
        return s.Length <= max ? s : s[..max] + "…";
    }

    static Dictionary<string, DesktopSession> LoadDesktopSessions(string root)
    {
        var best = new Dictionary<string, DesktopSession>();
        if (!Directory.Exists(root)) return best;
        foreach (var file in Directory.EnumerateFiles(root, "*.json", SearchOption.AllDirectories))
        {
            JsonNode? obj;
            try { obj = JsonNode.Parse(File.ReadAllText(file)); } catch { continue; }
            var cliId = obj?["cliSessionId"]?.GetValue<string>();
            var desktopId = obj?["sessionId"]?.GetValue<string>();
            if (cliId == null || desktopId == null) continue;
            if (obj?["isArchived"]?.GetValue<bool>() == true) continue;
            var title = obj?["title"]?.GetValue<string>();
            if (title == "") title = null;
            var activity = obj?["lastActivityAt"]?.GetValue<double>() ?? 0;
            var candidate = new DesktopSession { DesktopId = desktopId, Title = title, Activity = activity };
            if (best.TryGetValue(cliId, out var existing))
            {
                var exRank = (existing.Title != null ? 1 : 0, existing.Activity);
                var caRank = (candidate.Title != null ? 1 : 0, candidate.Activity);
                if (caRank.CompareTo(exRank) <= 0) continue;
            }
            best[cliId] = candidate;
        }
        return best;
    }

    static IEnumerable<string> SafeDirs(string p)
    {
        try { return Directory.GetDirectories(p); } catch { return Array.Empty<string>(); }
    }

    static IEnumerable<string> SafeFiles(string p, string pattern)
    {
        try { return Directory.GetFiles(p, pattern); } catch { return Array.Empty<string>(); }
    }
}

static class HookInstaller
{
    const string Marker = "task-monitor-hook.ps1";
    static readonly string[] Events = {
        "UserPromptSubmit", "PreToolUse", "PermissionRequest", "Notification", "Stop",
        "SubagentStart", "SubagentStop", "SessionEnd"
    };

    const string ScriptBody = @"# Claude Task Monitor hook: records precise session status from Claude Code events.
$raw = [Console]::In.ReadToEnd()
try { $d = $raw | ConvertFrom-Json } catch { exit 0 }
$sid = $d.session_id
$ev = $d.hook_event_name
if (-not $sid) { exit 0 }
$base = Join-Path $env:USERPROFILE '.claude\task-monitor'
New-Item -ItemType Directory -Force -Path $base | Out-Null
$agents = Join-Path $base ""$sid.agents""
if ($ev -eq 'SubagentStart' -or $ev -eq 'SubagentStop') {
  $aid = $d.agent_id
  if (-not $aid) { $aid = $d.subagent_id }
  if (-not $aid) { $aid = $d.task_id }
  if (-not $aid) { $aid = $d.tool_use_id }
  if ($aid) {
    $aid = ""$aid"" -replace '[\\/:]', '_'
    if ($ev -eq 'SubagentStart') {
      New-Item -ItemType Directory -Force -Path $agents | Out-Null
      New-Item -ItemType File -Force -Path (Join-Path $agents $aid) | Out-Null
    } else {
      Remove-Item -Force -ErrorAction SilentlyContinue (Join-Path $agents $aid)
    }
  }
  exit 0
}
$state = $null
switch ($ev) {
  'UserPromptSubmit'  { $state = 'working' }
  'PreToolUse'        { $state = 'working' }
  'PermissionRequest' { $state = 'needs_input' }
  'Notification'      { $state = 'needs_input' }
  'Stop'              { $state = 'done' }
  'SessionEnd'        {
    if (Test-Path $agents) { Remove-Item -Force -Recurse -ErrorAction SilentlyContinue ""$agents\*"" }
    $state = 'done'
  }
}
if ($state) {
  $ts = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() / 1000.0
  @{ state = $state; event = $ev; ts = $ts } | ConvertTo-Json -Compress |
    Set-Content -Path (Join-Path $base ""$sid.json"") -Encoding UTF8
}
exit 0
";

    public static bool IsInstalled()
    {
        try
        {
            return File.Exists(Paths.HookScript)
                && File.Exists(Paths.SettingsJson)
                && File.ReadAllText(Paths.SettingsJson).Contains(Marker);
        }
        catch { return false; }
    }

    public static void Install()
    {
        Directory.CreateDirectory(Paths.ClaudeDir);
        File.WriteAllText(Paths.HookScript, ScriptBody);

        JsonObject root = new();
        if (File.Exists(Paths.SettingsJson))
            root = JsonNode.Parse(File.ReadAllText(Paths.SettingsJson)) as JsonObject
                ?? throw new Exception("settings.json exists but is not valid JSON — fix it manually first.");

        var hooks = root["hooks"] as JsonObject ?? new JsonObject();
        // Absolute script path baked in so the command works from PowerShell or Git Bash.
        var command = $"powershell -NoProfile -ExecutionPolicy Bypass -File \"{Paths.HookScript}\"";
        foreach (var ev in Events)
        {
            var entries = hooks[ev] as JsonArray ?? new JsonArray();
            var present = entries.Any(e =>
                (e?["hooks"] as JsonArray)?.Any(h =>
                    (h?["command"]?.GetValue<string>() ?? "").Contains(Marker)) == true);
            if (!present)
            {
                entries.Add(new JsonObject
                {
                    ["hooks"] = new JsonArray(new JsonObject
                    {
                        ["type"] = "command",
                        ["command"] = command,
                        ["async"] = true,
                    })
                });
            }
            hooks[ev] = entries;
        }
        root["hooks"] = hooks;
        File.WriteAllText(Paths.SettingsJson,
            root.ToJsonString(new JsonSerializerOptions { WriteIndented = true }));
    }

    public static void Uninstall()
    {
        if (File.Exists(Paths.SettingsJson)
            && JsonNode.Parse(File.ReadAllText(Paths.SettingsJson)) is JsonObject root
            && root["hooks"] is JsonObject hooks)
        {
            foreach (var ev in Events)
            {
                if (hooks[ev] is not JsonArray entries) continue;
                var keep = new JsonArray();
                foreach (var e in entries.ToList())
                {
                    var inner = e?["hooks"] as JsonArray;
                    var ours = inner != null && inner.Count > 0 && inner.All(h =>
                        (h?["command"]?.GetValue<string>() ?? "").Contains(Marker));
                    if (!ours) { entries.Remove(e!); keep.Add(e!); }
                    else entries.Remove(e!);
                }
                if (keep.Count == 0) hooks.Remove(ev); else hooks[ev] = keep;
            }
            if (hooks.Count == 0) root.Remove("hooks");
            File.WriteAllText(Paths.SettingsJson,
                root.ToJsonString(new JsonSerializerOptions { WriteIndented = true }));
        }
        try { File.Delete(Paths.HookScript); } catch { }
        try { Directory.Delete(Paths.TaskMonitor, true); } catch { }
    }
}

class PanelForm : Form
{
    readonly System.Windows.Forms.Timer timer = new() { Interval = 2000 };
    readonly FlowLayoutPanel list = new()
    {
        Dock = DockStyle.Fill, FlowDirection = FlowDirection.TopDown,
        WrapContents = false, AutoScroll = true, BackColor = Color.FromArgb(30, 30, 32),
    };

    public PanelForm()
    {
        Text = "Claude Tasks";
        FormBorderStyle = FormBorderStyle.SizableToolWindow;
        TopMost = true;
        ShowInTaskbar = false;
        StartPosition = FormStartPosition.Manual;
        var wa = Screen.PrimaryScreen!.WorkingArea;
        Bounds = new Rectangle(wa.Right - 380, wa.Top + 20, 360, 480);
        BackColor = Color.FromArgb(30, 30, 32);
        Controls.Add(list);
        timer.Tick += (_, _) => Refresh_();
        timer.Start();
        Refresh_();
    }

    protected override void OnFormClosing(FormClosingEventArgs e)
    {
        if (e.CloseReason == CloseReason.UserClosing) { e.Cancel = true; Hide(); }
        base.OnFormClosing(e);
    }

    public void Refresh_()
    {
        List<SessionInfo> sessions;
        try { sessions = Scanner.Scan(); } catch { return; }

        Program.UpdateTray(sessions);
        list.SuspendLayout();
        list.Controls.Clear();
        foreach (var s in sessions) list.Controls.Add(MakeRow(s));
        if (sessions.Count == 0)
        {
            list.Controls.Add(new Label
            {
                Text = "No Claude Code sessions active in the last 8 hours",
                ForeColor = Color.Gray, AutoSize = true, Padding = new Padding(14),
            });
        }
        list.ResumeLayout();
    }

    Control MakeRow(SessionInfo s)
    {
        var (color, label) = s.Status switch
        {
            SessionStatus.Working => (Color.DodgerBlue, "Working…"),
            SessionStatus.NeedsInput => (Color.Orange, "Needs input"),
            _ => (Color.MediumSeaGreen, "Done"),
        };
        if (s.AgentCount > 0) label += $" · {s.AgentCount} agent{(s.AgentCount == 1 ? "" : "s")} running";

        var row = new Panel { Width = list.ClientSize.Width - 20, Height = 74, Cursor = Cursors.Hand };
        var dot = new Label { Text = "●", ForeColor = color, Location = new Point(6, 6), AutoSize = true };
        var title = new Label
        {
            Text = s.Name + (s.Kind == SessionKind.Cowork ? "   [Cowork]" : ""),
            ForeColor = Color.White, Font = new Font(Font, FontStyle.Bold),
            Location = new Point(26, 6), Width = row.Width - 32, AutoEllipsis = true,
        };
        var msg = new Label
        {
            Text = s.LastMessage, ForeColor = Color.LightGray,
            Location = new Point(26, 26), Width = row.Width - 32, Height = 28, AutoEllipsis = true,
        };
        var status = new Label { Text = label, ForeColor = color, Location = new Point(26, 54), AutoSize = true };
        row.Controls.AddRange(new Control[] { dot, title, msg, status });
        foreach (Control c in new Control[] { row, dot, title, msg, status })
            c.Click += (_, _) => Open(s);
        return row;
    }

    static void Open(SessionInfo s)
    {
        if (s.DesktopId == null) return;
        var route = s.Kind == SessionKind.Cowork ? "local_sessions" : "claude-code-desktop";
        try
        {
            Process.Start(new ProcessStartInfo
            {
                FileName = $"claude://claude.ai/{route}/{s.DesktopId}",
                UseShellExecute = true,
            });
        }
        catch { }
    }
}

static class Program
{
    static NotifyIcon? tray;
    static PanelForm? panel;

    [STAThread]
    static void Main(string[] args)
    {
        if (args.Contains("--install-hooks")) { HookInstaller.Install(); Console.WriteLine("Task Monitor hooks installed"); return; }
        if (args.Contains("--uninstall-hooks")) { HookInstaller.Uninstall(); Console.WriteLine("Task Monitor hooks removed"); return; }

        ApplicationConfiguration.Initialize();
        panel = new PanelForm();

        var menu = new ContextMenuStrip();
        menu.Items.Add("Show/Hide Panel", null, (_, _) => { if (panel.Visible) panel.Hide(); else panel.Show(); });
        var hookItem = new ToolStripMenuItem("Enable Precise Status Hooks");
        hookItem.Click += (_, _) =>
        {
            try
            {
                if (HookInstaller.IsInstalled()) HookInstaller.Uninstall(); else HookInstaller.Install();
            }
            catch (Exception ex) { MessageBox.Show(ex.Message, "Claude Task Monitor"); }
        };
        menu.Opening += (_, _) => hookItem.Text =
            HookInstaller.IsInstalled() ? "Disable Precise Status Hooks" : "Enable Precise Status Hooks";
        menu.Items.Add(hookItem);
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("Quit", null, (_, _) => { tray!.Visible = false; Application.Exit(); });

        tray = new NotifyIcon
        {
            Icon = SystemIcons.Application,
            Text = "Claude Task Monitor",
            Visible = true,
            ContextMenuStrip = menu,
        };
        tray.Click += (_, e) =>
        {
            if (e is MouseEventArgs m && m.Button == MouseButtons.Left)
            {
                if (panel.Visible) panel.Hide(); else { panel.Show(); panel.Refresh_(); }
            }
        };

        panel.Show();
        Application.Run();
    }

    public static void UpdateTray(List<SessionInfo> sessions)
    {
        if (tray == null) return;
        var needing = sessions.Count(s => s.Status == SessionStatus.NeedsInput);
        var working = sessions.Count(s => s.Status == SessionStatus.Working);
        var text = "Claude Task Monitor";
        if (needing > 0 || working > 0) text = $"Claude Tasks — {needing} need input, {working} working";
        tray.Text = text.Length > 63 ? text[..63] : text;   // NotifyIcon caps at 63 chars
    }
}
