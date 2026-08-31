import Charts
import SwiftUI
import UserNotifications

// MARK: - Phosphor icons (vendored SVGs, see icons/LICENSE)

// macOS renders SVG through NSImage directly, so the icons need no asset
// catalog and no package: template mode lets SwiftUI tint them like symbols.
enum Ph {
    static let lightningFill = load("lightning-fill")
    static let moonFill = load("moon-fill")
    static let warningFill = load("warning-fill")
    static let checkCircleFill = load("check-circle-fill")
    static let questionFill = load("question-fill")
    static let hexagonBold = load("hexagon-bold")
    static let listDashesBold = load("list-dashes-bold")
    static let moonStarsDuotone = load("moon-stars-duotone")
    static let chartBarBold = load("chart-bar-bold")
    static let minusBold = load("minus-bold")
    static let plusBold = load("plus-bold")
    static let cornersOutBold = load("corners-out-bold")
    static let magnifyingGlassBold = load("magnifying-glass-bold")
    static let xBold = load("x-bold")

    static let names = [
        "lightning-fill", "moon-fill", "warning-fill", "check-circle-fill",
        "question-fill", "hexagon-bold", "list-dashes-bold", "moon-stars-duotone",
        "chart-bar-bold", "minus-bold", "plus-bold", "corners-out-bold",
        "magnifying-glass-bold", "x-bold",
    ]

    static func url(_ name: String) -> URL? {
        Bundle.main.url(forResource: name, withExtension: "svg", subdirectory: "icons")
    }

    private static func load(_ name: String) -> Image {
        guard let url = url(name), let image = NSImage(contentsOf: url)
        else { return Image(systemName: "questionmark") }
        image.isTemplate = true
        return Image(nsImage: image).renderingMode(.template).resizable()
    }
}

// MARK: - Data

struct ClaudeSessionFile: Decodable {
    let pid: Int32
    let sessionId: String
    let cwd: String
    let name: String
    let status: String?
    let version: String?
    let startedAt: Double? // ms since epoch
}

struct HerdrAgent: Decodable {
    struct AgentSession: Decodable { let value: String }
    let agent: String // claude | codex | ...
    let agentSession: AgentSession? // codex reports no session id
    let agentStatus: String
    let terminalId: String
    let cwd: String
    let focused: Bool
}

// herdr is a third party CLI whose JSON is not a stable contract, and a
// strict array decode would fail wholesale on one unexpected entry: every
// Claude session would drop to the coarse status field and every Codex tile
// would vanish. Decode per element and keep what parses.
struct LenientAgent: Decodable {
    let agent: HerdrAgent?
    init(from decoder: Decoder) throws {
        agent = try? HerdrAgent(from: decoder)
    }
}

struct HerdrAgentList: Decodable {
    struct Result: Decodable { let agents: [LenientAgent] }
    let result: Result
}

struct SessionTile: Identifiable, Equatable {
    let id: String // Claude sessionId, or herdr terminal id for Codex
    let agent: String // claude | codex
    let name: String
    let dir: String
    var status: String // idle | working | blocked | done | unknown
    let terminalId: String?
    let focused: Bool
    let pid: Int32? // Codex reports none, so it cannot be killed from here
    let cwd: String
    let version: String?
    let startedAt: Date?
    let model: String?
    let contextTokens: Int?
    let contextWindow: Int? // Codex reports it; Claude does not
    let host: String? // Ghostty, GoLand, WebStorm, ...
    let hostAppPath: String?
}

// MARK: - File streaming

// Streams a file line by line so a transcript is never held in memory whole.
// Transcripts reach tens of megabytes each, and mapping then decoding one into
// a String copies every byte.
func forEachLine(of url: URL, _ body: (String) -> Void) {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return }
    defer { try? handle.close() }
    var buffer = Data()
    while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
        buffer.append(chunk)
        var start = buffer.startIndex
        while let newline = buffer[start...].firstIndex(of: UInt8(ascii: "\n")) {
            if newline > start {
                body(String(decoding: buffer[start..<newline], as: UTF8.self))
            }
            start = buffer.index(after: newline)
        }
        buffer.removeSubrange(buffer.startIndex..<start)
    }
    if !buffer.isEmpty {
        body(String(decoding: buffer, as: UTF8.self))
    }
}

func parseISODate(_ text: String) -> Date? {
    (try? Date(text, strategy: Date.ISO8601FormatStyle(
        includingFractionalSeconds: true)))
        ?? (try? Date(text, strategy: .iso8601))
}

// MARK: - Caching

// The session list refreshes every 2 seconds, and re-reading every transcript
// tail and every Codex rollout header on each tick costs megabytes of reads and
// hundreds of JSON parses per minute. These caches key on the file's
// modification date and size, so an unchanged file is parsed once.
final class FileCache<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String: (stamp: Date, size: Int, value: Value)] = [:]
    // Content that never changes once written (a rollout's first line) can skip
    // the staleness check entirely.
    private let immutableContent: Bool

    init(immutableContent: Bool = false) {
        self.immutableContent = immutableContent
    }

    func value(for url: URL, compute: (URL) -> Value) -> Value {
        var stamp = Date.distantPast
        var size = 0
        if !immutableContent {
            let attributes = try? FileManager.default
                .attributesOfItem(atPath: url.path)
            stamp = attributes?[.modificationDate] as? Date ?? .distantPast
            size = attributes?[.size] as? Int ?? 0
        }

        lock.lock()
        if let hit = entries[url.path],
           immutableContent || (hit.stamp == stamp && hit.size == size) {
            lock.unlock()
            return hit.value
        }
        lock.unlock()

        let fresh = compute(url)
        lock.lock()
        // Rollout headers are ~20KB of parsed JSON each and the newest-N window
        // rotates over days, so the map would grow for the life of the process.
        if entries.count > 200 { entries.removeAll(keepingCapacity: true) }
        entries[url.path] = (stamp, size, fresh)
        lock.unlock()
        return fresh
    }
}

// A value recomputed at most once per interval.
final class TimedCache<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private let interval: TimeInterval
    private var computedAt = Date.distantPast
    private var value: Value?

    init(interval: TimeInterval) { self.interval = interval }

    func value(compute: () -> Value) -> Value {
        lock.lock()
        if let value, Date().timeIntervalSince(computedAt) < interval {
            lock.unlock()
            return value
        }
        lock.unlock()

        let fresh = compute()
        lock.lock()
        value = fresh
        computedAt = Date()
        lock.unlock()
        return fresh
    }
}

// MARK: - Subprocesses

@discardableResult
func runCommand(_ path: String, _ args: [String],
                timeout: TimeInterval = 5) -> Data {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    do {
        try p.run()
    } catch {
        return Data()
    }
    // Without this, a wedged helper parks a cooperative-pool thread forever and
    // the 2 second refresh keeps adding more until the pool is exhausted.
    let watchdog = DispatchWorkItem {
        if p.isRunning { p.terminate() }
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout,
                                      execute: watchdog)
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    watchdog.cancel()
    return data
}

// MARK: - Herdr CLI

enum Herdr {
    // Known install locations first, then PATH. Process does no PATH lookup of
    // its own, so without the env fallback anyone whose herdr lives somewhere
    // else (/usr/bin, ~/bin, ~/go/bin, a Nix profile) got no sessions and no
    // diagnostic. Resolved per call so installing herdr while the app runs
    // takes effect.
    static func resolve() -> (path: String, args: [String]) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            home + "/.local/bin/herdr",
            "/opt/homebrew/bin/herdr",
            "/usr/local/bin/herdr",
        ]
        if let found = candidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) {
            return (found, [])
        }
        return ("/usr/bin/env", ["herdr"])
    }

    @discardableResult
    static func run(_ args: [String]) -> Data {
        let tool = resolve()
        return runCommand(tool.path, tool.args + args)
    }

    static func agents() -> [HerdrAgent] {
        let data = run(["agent", "list"])
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return (try? decoder.decode(HerdrAgentList.self, from: data))?
            .result.agents.compactMap(\.agent) ?? []
    }

    // Claude sessions join by session id; Codex reports none.
    static func bySessionId(_ agents: [HerdrAgent]) -> [String: HerdrAgent] {
        var map: [String: HerdrAgent] = [:]
        for agent in agents {
            if let id = agent.agentSession?.value { map[id] = agent }
        }
        return map
    }
}

// MARK: - Host detection (which app the session runs in)

enum Hosts {
    // pid -> (ppid, command path) for every process.
    static func processTable() -> [Int32: (ppid: Int32, comm: String)] {
        let data = runCommand("/bin/ps", ["-axo", "pid=,ppid=,comm="])
        guard let text = String(data: data, encoding: .utf8) else { return [:] }
        var table: [Int32: (Int32, String)] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 2,
                                   omittingEmptySubsequences: true)
            guard parts.count == 3,
                  let pid = Int32(parts[0]), let ppid = Int32(parts[1])
            else { continue }
            table[pid] = (ppid, String(parts[2]))
        }
        return table
    }

    struct HostApp: Equatable {
        let name: String
        let appPath: String? // nil for a bare CLI multiplexer
    }

    // Change these two for a different terminal. herdr runs as a detached
    // server, so its process ancestry ends at launchd rather than at the
    // terminal drawing it, which is why the terminal is named rather than
    // detected. Everything not behind herdr is detected from the process tree.
    static let herdrTerminalBundleID = "com.mitchellh.ghostty"
    static let herdrTerminalLabel = "Ghostty · herdr"

    static let herdrTerminalPath: String? = NSWorkspace.shared
        .urlForApplication(withBundleIdentifier: herdrTerminalBundleID)?.path

    // Climb the parent chain until an .app bundle or a known host shows up.
    static func host(of pid: Int32,
                     table: [Int32: (ppid: Int32, comm: String)]) -> HostApp? {
        var current = pid
        for _ in 0..<15 {
            guard let entry = table[current] else { return nil }
            let comm = entry.comm
            // The outermost .app wins, so helper bundles report their host app.
            if let range = comm.range(of: ".app/") {
                let path = String(comm[..<range.lowerBound]) + ".app"
                let name = (path as NSString).lastPathComponent
                    .replacingOccurrences(of: ".app", with: "")
                return HostApp(name: name, appPath: path)
            }
            let base = (comm as NSString).lastPathComponent
            // ponytail: herdr is a detached server, its ancestry ends at launchd.
            // This user's herdr renders in Ghostty (see dev-setup repo).
            if base == "herdr" {
                return HostApp(name: herdrTerminalLabel,
                               appPath: herdrTerminalPath)
            }
            if ["tmux", "zellij", "screen"].contains(base) {
                return HostApp(name: base, appPath: nil)
            }
            current = entry.ppid
            if current <= 1 { return nil }
        }
        return nil
    }
}

// MARK: - Transcript info (model, context size)

enum Transcript {
    // ~/.claude/projects/<slug>/<sessionId>.jsonl, where Claude Code replaces
    // every character outside [A-Za-z0-9] with a dash. Replacing only "/" and
    // "." silently missed any path with a space, an underscore or a tilde,
    // which meant no model and no context for those sessions.
    static func path(sessionId: String, cwd: String) -> String {
        let slug = String(cwd.map { character in
            character.isASCII && (character.isLetter || character.isNumber)
                ? character : "-"
        })
        return FileManager.default.homeDirectoryForCurrentUser.path
            + "/.claude/projects/\(slug)/\(sessionId).jsonl"
    }

    private static let cache = FileCache<(model: String?, tokens: Int?)>()

    // Read the tail and take model + usage from the last assistant message.
    static func info(sessionId: String, cwd: String) -> (model: String?, tokens: Int?) {
        let file = path(sessionId: sessionId, cwd: cwd)
        guard FileManager.default.fileExists(atPath: file) else { return (nil, nil) }
        return cache.value(for: URL(fileURLWithPath: file)) { _ in
            parse(file)
        }
    }

    private static func parse(_ file: String) -> (model: String?, tokens: Int?) {
        guard let fh = FileHandle(forReadingAtPath: file)
        else { return (nil, nil) }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        let tailLength: UInt64 = 128 * 1024
        try? fh.seek(toOffset: size > tailLength ? size - tailLength : 0)
        // Decoding, not String(data:encoding:): a tail seek lands mid-codepoint
        // often enough that the strict initialiser returned nil and the model
        // and context flickered away every couple of seconds.
        guard let data = try? fh.readToEnd() else { return (nil, nil) }
        let text = String(decoding: data, as: UTF8.self)

        for line in text.split(separator: "\n").reversed() {
            guard line.contains("\"usage\""),
                  let obj = try? JSONSerialization.jsonObject(
                    with: Data(line.utf8)) as? [String: Any],
                  let message = obj["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any]
            else { continue }
            let tokens = ["input_tokens", "cache_creation_input_tokens",
                          "cache_read_input_tokens"]
                .compactMap { usage[$0] as? Int }.reduce(0, +)
            return (message["model"] as? String, tokens > 0 ? tokens : nil)
        }
        return (nil, nil)
    }
}

// MARK: - Account usage (live from Anthropic, not calculated)

struct UsageLimit: Decodable, Equatable, Identifiable {
    struct Scope: Decodable, Equatable {
        struct ScopeModel: Decodable, Equatable { let displayName: String? }
        let model: ScopeModel?
    }
    let kind: String
    let percent: Double
    let severity: String?
    let resetsAt: Date?
    let scope: Scope?
    // Codex only: it reports one window of arbitrary length instead of the
    // fixed session/weekly pair Claude reports.
    var windowMinutes: Int?

    var id: String { kind + (scope?.model?.displayName ?? "") }
    var agent: String { kind.hasPrefix("codex") ? "codex" : "claude" }

    // Int(Double) traps on NaN, infinity, or anything past Int64, and this
    // number arrives over the network.
    var wholePercent: Int {
        guard percent.isFinite else { return 0 }
        return Int(min(max(percent, 0), 100).rounded())
    }

    private var windowName: String {
        guard let minutes = windowMinutes, minutes > 0 else { return "window" }
        if minutes % 1440 == 0 { return "\(minutes / 1440)d" }
        return "\(minutes / 60)h"
    }

    var label: String {
        switch kind {
        case "session": return "Session"
        case "weekly_all": return "Week · all models"
        case "weekly_scoped":
            return "Week · \(scope?.model?.displayName ?? "model")"
        case "codex_primary", "codex_secondary": return "Codex · \(windowName)"
        default: return kind.replacingOccurrences(of: "_", with: " ")
        }
    }

    var shortLabel: String {
        switch kind {
        case "session": return "5h"
        case "weekly_all": return "7d"
        case "weekly_scoped": return scope?.model?.displayName ?? "model"
        case "codex_primary", "codex_secondary": return "cdx \(windowName)"
        default: return kind.replacingOccurrences(of: "_", with: " ")
        }
    }
}

enum Usage {
    struct Response: Decodable { let limits: [UsageLimit] }

    // Claude Code's own OAuth token, from the login keychain.
    // ponytail: goes through /usr/bin/security instead of SecItemCopyMatching —
    // this ad-hoc binary changes every rebuild and would re-trigger the
    // keychain permission prompt each time; the security CLI is already trusted.
    static func token() -> String? {
        let data = runCommand("/usr/bin/security",
                              ["find-generic-password",
                               "-s", "Claude Code-credentials", "-w"])
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = obj["claudeAiOauth"] as? [String: Any]
        else { return nil }
        return oauth["accessToken"] as? String
    }

    static func fetch() async -> [UsageLimit] {
        guard let token = token(),
              let url = URL(string: "https://api.anthropic.com/api/oauth/usage")
        else { return [] }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return [] }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { d in
            let s = try d.singleValueContainer().decode(String.self)
            if let date = (try? Date(
                s, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
                ?? (try? Date(s, strategy: .iso8601)) { return date }
            throw DecodingError.dataCorrupted(.init(
                codingPath: d.codingPath, debugDescription: "bad date \(s)"))
        }
        return (try? decoder.decode(Response.self, from: data))?.limits ?? []
    }
}

// MARK: - Historical stats (from local transcripts)

// The account endpoint reports only current utilization, with no history and
// no per-model token counts, so daily charts come from the transcript files.
// These are raw tokens: the plan's percentages are weighted per model and the
// weights are not published, so the two numbers do not convert into each other.
enum Stats {
    struct Point: Identifiable, Equatable {
        let day: Date
        let model: String
        let tokens: Int
        let output: Int
        var id: String { "\(day.timeIntervalSince1970)-\(model)" }
    }

    static let projectsRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/projects")

    static func prettyModel(_ model: String) -> String {
        model.replacingOccurrences(of: "claude-", with: "")
            .split(separator: "-")
            .map { $0.first!.uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    static func scan(days: Int = 14) -> [Point] {
        let fm = FileManager.default
        let calendar = Calendar.current
        let cutoff = calendar.date(
            byAdding: .day, value: -(days - 1),
            to: calendar.startOfDay(for: .now))!
        guard let files = fm.enumerator(
            at: projectsRoot,
            includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }

        // Keyed by local day. Bucketing on the timestamp's UTC date while
        // cutting off at local midnight dropped the oldest bar and filed
        // evening work under the wrong day everywhere except UTC.
        var agg: [Date: [String: (input: Int, output: Int)]] = [:]
        for case let url as URL in files where url.pathExtension == "jsonl" {
            // A file's last write is its newest entry, so an older file cannot
            // hold anything inside the window.
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            if let modified, modified < cutoff { continue }
            autoreleasepool {
                forEachLine(of: url) { line in
                    guard line.contains("\"usage\""),
                          let obj = try? JSONSerialization.jsonObject(
                            with: Data(line.utf8)) as? [String: Any],
                          let timestamp = obj["timestamp"] as? String,
                          let moment = parseISODate(timestamp),
                          moment >= cutoff,
                          let message = obj["message"] as? [String: Any],
                          let usage = message["usage"] as? [String: Any],
                          let model = message["model"] as? String,
                          !model.hasPrefix("<")
                    else { return }
                    let day = calendar.startOfDay(for: moment)
                    let input = ["input_tokens", "cache_creation_input_tokens",
                                 "cache_read_input_tokens"]
                        .compactMap { usage[$0] as? Int }.reduce(0, +)
                    let output = usage["output_tokens"] as? Int ?? 0
                    let previous = agg[day]?[model] ?? (0, 0)
                    agg[day, default: [:]][model] =
                        (previous.input + input, previous.output + output)
                }
            }
        }

        return agg.flatMap { day, models in
            models.map { model, counts in
                Point(day: day, model: model,
                      tokens: counts.input, output: counts.output)
            }
        }
        .sorted { ($0.day, $0.model) < ($1.day, $1.model) }
    }
}

// MARK: - Codex rollouts

// Codex has no live session registry like ~/.claude/sessions, so herdr supplies
// which sessions exist and their status, and the rollout files supply model,
// context and plan usage. Rollouts are matched by working directory because the
// herdr codex integration reports no session id.
enum Codex {
    static let root = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex/sessions")

    struct Info {
        var model: String?
        var tokens: Int?
        var contextWindow: Int?
        var name: String?
    }

    // session_meta never changes once written, so it needs no staleness check.
    private static let metaCache = FileCache<[String: Any]?>(immutableContent: true)
    private static let infoCache = FileCache<Info>()
    private static let filesCache = TimedCache<[URL]>(interval: 10)

    // Newest rollout files first. Only a handful are ever relevant. The
    // directory walk stats every rollout, so it is refreshed on an interval
    // rather than on every 2 second tick.
    static func recentFiles(limit: Int = 40) -> [URL] {
        Array(filesCache.value { scanFiles() }.prefix(limit))
    }

    private static func scanFiles() -> [URL] {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys) else { return [] }
        var found: [(URL, Date)] = []
        for case let url as URL in walker where url.pathExtension == "jsonl" {
            let modified = (try? url.resourceValues(forKeys: Set(keys)))?
                .contentModificationDate ?? .distantPast
            found.append((url, modified))
        }
        // Bounded so a long history cannot grow this list without limit; the
        // caller takes what it needs from the newest end.
        return found.sorted { $0.1 > $1.1 }.prefix(200).map(\.0)
    }

    static func firstLine(_ url: URL) -> [String: Any]? {
        metaCache.value(for: url) { readFirstLine($0) }
    }

    // The session_meta line embeds the full system prompt, so it runs to tens of
    // kilobytes; read until the newline instead of guessing a chunk size.
    private static func readFirstLine(_ url: URL) -> [String: Any]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var buffer = Data()
        while buffer.count < 1_048_576 {
            guard let chunk = try? handle.read(upToCount: 64 * 1024),
                  !chunk.isEmpty else { break }
            buffer.append(chunk)
            if let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                buffer = buffer[buffer.startIndex..<newline]
                break
            }
        }
        guard let obj = try? JSONSerialization.jsonObject(with: buffer)
                as? [String: Any] else { return nil }
        return obj["payload"] as? [String: Any]
    }

    private static func tailObjects(_ url: URL, bytes: Int = 96 * 1024)
        -> [[String: Any]] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > UInt64(bytes)
                         ? size - UInt64(bytes) : 0)
        guard let data = try? handle.readToEnd() else { return [] }
        // See Transcript.parse: a tail seek can split a multi-byte character.
        let text = String(decoding: data, as: UTF8.self)
        return text.split(separator: "\n").compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8))
                as? [String: Any]
        }.compactMap { $0 }
    }

    // A session's own rollout, not one of the subagent rollouts it spawns.
    private static func isMainSession(_ meta: [String: Any], cwd: String) -> Bool {
        guard meta["cwd"] as? String == cwd else { return false }
        if let source = meta["source"] as? [String: Any],
           source["subagent"] != nil { return false }
        return true
    }

    static func info(cwd: String, files: [URL]) -> Info {
        guard let url = files.first(where: {
            guard let meta = firstLine($0) else { return false }
            return isMainSession(meta, cwd: cwd)
        }) else { return Info() }
        // Keyed on the rollout's mtime, so an active session re-parses and an
        // idle one does not.
        return infoCache.value(for: url) { parseInfo($0) }
    }

    private static func parseInfo(_ url: URL) -> Info {
        var info = Info()
        info.name = firstLine(url)?["thread_name"] as? String
        for object in tailObjects(url).reversed() {
            guard let payload = object["payload"] as? [String: Any] else { continue }
            let recordType = object["type"] as? String
            let payloadType = payload["type"] as? String

            if info.tokens == nil, payloadType == "token_count",
               let detail = payload["info"] as? [String: Any] {
                info.contextWindow = detail["model_context_window"] as? Int
                // last_token_usage, not total: the total accumulates over the
                // whole session and runs past the context window.
                if let last = detail["last_token_usage"] as? [String: Any] {
                    info.tokens = last["input_tokens"] as? Int
                }
            }
            // The model lives on turn_context (an outer record type, so its
            // payload carries no type) or on a thread_settings_applied event
            // when the model was switched mid-session.
            if info.model == nil {
                if recordType == "turn_context" {
                    info.model = payload["model"] as? String
                } else if payloadType == "thread_settings_applied",
                          let settings = payload["thread_settings"]
                            as? [String: Any] {
                    info.model = settings["model"] as? String
                }
            }
            if info.tokens != nil, info.model != nil { break }
        }
        return info
    }

    // Plan usage is account-wide, so any recent rollout carries it. Codex
    // reports a primary and an optional secondary window, and which is which
    // depends on the plan: a ChatGPT plan shares a five-hour allowance and can
    // carry an extra weekly limit, while this account's "go" plan reports a
    // single 30-day window. So take both and label each from its own window
    // length rather than assuming either shape. With an API key instead of a
    // ChatGPT plan there are no plan percentages at all, and no gauge appears.
    static func planLimits(files: [URL]) -> [UsageLimit] {
        for url in files.prefix(8) {
            for object in tailObjects(url).reversed() {
                guard let payload = object["payload"] as? [String: Any],
                      let limits = payload["rate_limits"] as? [String: Any]
                else { continue }
                let found = ["primary", "secondary"].compactMap { key -> UsageLimit? in
                    guard let window = limits[key] as? [String: Any],
                          let percent = window["used_percent"] as? Double
                    else { return nil }
                    return UsageLimit(
                        kind: "codex_\(key)", percent: percent,
                        severity: percent >= 80 ? "warning" : "normal",
                        resetsAt: (window["resets_at"] as? Double)
                            .map { Date(timeIntervalSince1970: $0) },
                        scope: nil,
                        windowMinutes: window["window_minutes"] as? Int)
                }
                if !found.isEmpty { return found }
            }
        }
        return []
    }
}

// MARK: - Session loading

enum Sessions {
    static let dir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/sessions")

    static func load() -> [SessionTile] {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        let agents = Herdr.agents()
        let herdr = Herdr.bySessionId(agents)
        let processes = Hosts.processTable()

        var tiles: [SessionTile] = []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let session = try? decoder.decode(ClaudeSessionFile.self, from: data)
            else { continue }
            // A session file can outlive its process and macOS recycles pids,
            // so the pid must still be alive AND still be a claude process.
            // Without the identity check a recycled pid renders a ghost tile
            // whose Kill action would signal an unrelated process. The pid > 0
            // guard matters more: kill(0, ...) targets our own process group.
            guard session.pid > 0,
                  let process = processes[session.pid],
                  (process.comm as NSString).lastPathComponent
                    .contains("claude")
            else { continue }

            let agent = herdr[session.sessionId]
            let status = agent?.agentStatus
                ?? session.status.map { $0 == "busy" ? "working" : $0 }
                ?? "unknown"
            let transcript = Transcript.info(
                sessionId: session.sessionId, cwd: session.cwd)
            let hostApp = Hosts.host(of: session.pid, table: processes)
            tiles.append(SessionTile(
                id: session.sessionId,
                agent: "claude",
                name: session.name,
                dir: (session.cwd as NSString).lastPathComponent,
                status: status,
                terminalId: agent?.terminalId,
                focused: agent?.focused ?? false,
                pid: session.pid,
                cwd: session.cwd,
                version: session.version,
                startedAt: session.startedAt.map {
                    Date(timeIntervalSince1970: $0 / 1000) },
                model: transcript.model,
                contextTokens: transcript.tokens,
                contextWindow: nil,
                host: hostApp?.name,
                hostAppPath: hostApp?.appPath
            ))
        }
        tiles.append(contentsOf: codexTiles(agents: agents))
        return tiles.sorted { $0.name < $1.name }
    }

    // Codex sessions come from herdr, since Codex writes no live registry.
    private static func codexTiles(agents: [HerdrAgent]) -> [SessionTile] {
        let codex = agents.filter { $0.agent == "codex" }
        guard !codex.isEmpty else { return [] }
        let files = Codex.recentFiles()

        return codex.map { agent in
            let info = Codex.info(cwd: agent.cwd, files: files)
            let dir = (agent.cwd as NSString).lastPathComponent
            return SessionTile(
                id: agent.terminalId,
                agent: "codex",
                name: info.name?.isEmpty == false ? info.name! : dir,
                dir: dir,
                status: agent.agentStatus,
                terminalId: agent.terminalId,
                focused: agent.focused,
                pid: nil,
                cwd: agent.cwd,
                version: nil,
                startedAt: nil,
                model: info.model,
                contextTokens: info.tokens,
                contextWindow: info.contextWindow,
                host: Hosts.herdrTerminalLabel,
                hostAppPath: Hosts.herdrTerminalPath
            )
        }
    }
}

// MARK: - Model

@MainActor
final class Model: ObservableObject {
    @Published var tiles: [SessionTile] = []
    @Published var usageLimits: [UsageLimit] = []

    var agentCounts: [String: Int] {
        Dictionary(grouping: tiles, by: \.agent).mapValues(\.count)
    }
    private var timer: Timer?
    private var usageTimer: Timer?
    // The 2 second timer fires whether or not the previous scan finished.
    private var refreshing = false
    // Session ids that finished work: went working -> idle and were not clicked yet.
    private var doneIds: Set<String> = []

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
        refreshUsage()
        // 5 minutes: the endpoint rate-limits (429) well before utilization
        // percentages change meaningfully. A failed fetch keeps the last
        // values rather than blanking the panel.
        usageTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) {
            [weak self] _ in self?.refreshUsage()
        }
    }

    nonisolated func refreshUsage() {
        Task.detached(priority: .utility) {
            var collected = await Usage.fetch()
            // Codex plan usage rides along in its rollout files, so it needs no
            // request and survives the Claude endpoint rate-limiting.
            collected.append(contentsOf:
                Codex.planLimits(files: Codex.recentFiles(limit: 8)))
            let limits = collected
            guard !limits.isEmpty else { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                if self.usageLimits != limits { self.usageLimits = limits }
                self.alertGate(limits)
            }
        }
    }

    // Notify once per limit per reset window when usage crosses 80%.
    private func alertGate(_ limits: [UsageLimit]) {
        for limit in limits where limit.percent >= 80 {
            let key = "usageAlert.\(limit.id)."
                + (limit.resetsAt?.timeIntervalSince1970.description ?? "-")
            guard !UserDefaults.standard.bool(forKey: key) else { continue }
            UserDefaults.standard.set(true, forKey: key)
            let content = UNMutableNotificationContent()
            content.title = "\(limit.agent.capitalized) usage at \(limit.wholePercent)%"
            content.body = limit.label + (limit.resetsAt.map {
                ", resets \($0.formatted(.relative(presentation: .named)))" } ?? "")
            content.sound = .default
            UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: key, content: content, trigger: nil))
        }
    }

    nonisolated func refresh() {
        Task { @MainActor [weak self] in
            guard let self, !self.refreshing else { return }
            self.refreshing = true
            defer { self.refreshing = false }
            let loaded = await Task.detached(priority: .utility) {
                Sessions.load()
            }.value
            do {
                let previous = Dictionary(
                    uniqueKeysWithValues: self.tiles.map { ($0.id, $0.status) })
                var tiles: [SessionTile] = []
                for tile in loaded {
                    switch tile.status {
                    case "idle" where previous[tile.id] == "working"
                        || previous[tile.id] == "done":
                        self.doneIds.insert(tile.id)
                    case "idle":
                        break
                    default:
                        self.doneIds.remove(tile.id)
                    }
                    var tile = tile
                    if self.doneIds.contains(tile.id), tile.status == "idle" {
                        tile.status = "done"
                    }
                    tiles.append(tile)
                }
                if self.tiles != tiles { self.tiles = tiles }
            }
        }
    }

    nonisolated func terminate(_ tile: SessionTile) {
        // A non-positive pid would signal our own process group, or every
        // process this user can signal.
        guard let pid = tile.pid, pid > 0 else { return }
        Darwin.kill(pid, SIGTERM)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(700))
            self.refresh()
        }
    }

    nonisolated func focus(_ tile: SessionTile) {
        Task { @MainActor in
            self.doneIds.remove(tile.id)
            self.refresh()
        }
        Task.detached(priority: .userInitiated) {
            if let terminalId = tile.terminalId {
                Herdr.run(["agent", "focus", terminalId])
            }
            // Activate whichever app hosts this session (Ghostty, GoLand, ...).
            // Tab-level focus only exists for herdr; IDE terminals cannot be
            // addressed, so those land on the app itself.
            guard let path = tile.hostAppPath else { return }
            await MainActor.run {
                let config = NSWorkspace.OpenConfiguration()
                config.activates = true
                NSWorkspace.shared.openApplication(
                    at: URL(fileURLWithPath: path), configuration: config)
            }
        }
    }
}

// MARK: - UI

func statusColor(_ status: String) -> Color {
    switch status {
    case "idle": return .green
    case "working": return .orange
    case "blocked": return .red
    case "done": return .blue
    default: return .gray
    }
}

func formatTokens(_ n: Int) -> String {
    if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
    if n >= 1000 { return String(format: "%.0fk", Double(n) / 1000) }
    return "\(n)"
}

// MARK: - Fuzzy filter

// Subsequence match: every query character must appear in order, so "wzenv"
// finds "wizard-of-envs". The score rewards consecutive hits and matches that
// start a word, which keeps the obvious candidate on top. nil means no match.
func fuzzyScore(_ query: String, _ candidate: String) -> Int? {
    let needle = Array(query.lowercased())
    guard !needle.isEmpty else { return 0 }
    let haystack = Array(candidate.lowercased())
    guard needle.count <= haystack.count else { return nil }

    var index = 0
    var score = 0
    var streak = 0
    for (position, character) in haystack.enumerated() {
        guard index < needle.count, character == needle[index] else {
            streak = 0
            continue
        }
        streak += 1
        var points = 1 + streak * 2
        let boundary = position == 0
            || "-_ /.:".contains(haystack[position - 1])
        if boundary { points += 6 }
        if position == 0 { points += 4 }
        score += points
        index += 1
    }
    return index == needle.count ? score : nil
}

// Best score over the fields worth searching, name weighted highest.
func tileScore(_ query: String, _ tile: SessionTile) -> Int? {
    let fields: [(String, Int)] = [
        (tile.name, 3), (tile.dir, 2), (tile.agent, 1),
        (tile.model ?? "", 1), (tile.host ?? "", 1), (tile.status, 1),
    ]
    let scores = fields.compactMap { field, weight in
        fuzzyScore(query, field).map { $0 * weight }
    }
    return scores.max()
}

enum ViewMode: String, CaseIterable, Identifiable {
    case orbs, table
    var id: String { rawValue }
}

func statusIcon(_ status: String) -> Image {
    switch status {
    case "idle": return Ph.moonFill
    case "working": return Ph.lightningFill
    case "blocked": return Ph.warningFill
    case "done": return Ph.checkCircleFill
    default: return Ph.questionFill
    }
}

// Slowly drifting mesh gradient. Gives the glass something to refract.
struct MeshBackground: View {
    @Environment(\.colorScheme) private var scheme

    private var colors: [Color] {
        scheme == .dark
            ? [Color(red: 0.05, green: 0.06, blue: 0.12),
               Color(red: 0.10, green: 0.08, blue: 0.22),
               Color(red: 0.04, green: 0.10, blue: 0.16),
               Color(red: 0.13, green: 0.07, blue: 0.18),
               Color(red: 0.06, green: 0.12, blue: 0.24),
               Color(red: 0.03, green: 0.05, blue: 0.10),
               Color(red: 0.09, green: 0.13, blue: 0.26),
               Color(red: 0.05, green: 0.09, blue: 0.20),
               Color(red: 0.11, green: 0.06, blue: 0.16)]
            : [Color(red: 0.90, green: 0.93, blue: 1.00),
               Color(red: 0.84, green: 0.88, blue: 1.00),
               Color(red: 0.93, green: 0.90, blue: 1.00),
               Color(red: 0.86, green: 0.94, blue: 1.00),
               Color(red: 0.96, green: 0.94, blue: 1.00),
               Color(red: 0.88, green: 0.91, blue: 0.99),
               Color(red: 0.92, green: 0.96, blue: 1.00),
               Color(red: 0.85, green: 0.90, blue: 1.00),
               Color(red: 0.94, green: 0.92, blue: 1.00)]
    }

    var body: some View {
        // ponytail: static mesh; a 12fps animated mesh cost ~20% CPU for a
        // background drift nobody stares at. Re-animate only if it earns it.
        MeshGradient(
            width: 3, height: 3,
            points: [
                [0, 0], [0.5, 0], [1, 0],
                [0, 0.5], [0.72, 0.38], [1, 0.5],
                [0, 1], [0.5, 1], [1, 1],
            ],
            colors: colors
        )
        .ignoresSafeArea()
    }
}

// ponytail: there is deliberately no animated "working" pulse. Every repeating
// animation under glassEffect recomposites the whole window: a 0.35s fade every
// 1.2s measured 12-21% CPU on a scrollable comb, versus 0-1.5% without it.
// Working sessions are marked statically instead (tint, bolt icon, brighter
// rim). Revisit only if glass compositing gets cheaper in a later macOS.

// Pointy-top regular hexagon with rounded corners.
struct Hexagon: Shape {
    var cornerRadius: CGFloat = 14

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.height / 2, rect.width / sqrt(3))
        let points = (0..<6).map { k -> CGPoint in
            let angle = (Double(k) * 60 - 90) * .pi / 180
            return CGPoint(x: center.x + radius * cos(angle),
                           y: center.y + radius * sin(angle))
        }
        var path = Path()
        for i in 0..<6 {
            let previous = points[(i + 5) % 6]
            let current = points[i]
            let next = points[(i + 1) % 6]
            let inVector = CGPoint(x: current.x - previous.x, y: current.y - previous.y)
            let outVector = CGPoint(x: next.x - current.x, y: next.y - current.y)
            let inLength = hypot(inVector.x, inVector.y)
            let outLength = hypot(outVector.x, outVector.y)
            let r = min(cornerRadius, inLength / 2, outLength / 2)
            let cornerStart = CGPoint(
                x: current.x - inVector.x / inLength * r,
                y: current.y - inVector.y / inLength * r)
            let cornerEnd = CGPoint(
                x: current.x + outVector.x / outLength * r,
                y: current.y + outVector.y / outLength * r)
            if i == 0 { path.move(to: cornerStart) } else { path.addLine(to: cornerStart) }
            path.addQuadCurve(to: cornerEnd, control: current)
        }
        path.closeSubpath()
        return path
    }
}

// Offset hex rows: odd rows shift half a cell, rows overlap by a quarter height.
struct HoneycombLayout: Layout {
    var cellWidth: CGFloat
    var spacing: CGFloat = 16
    // The caller fixes the row shape from the unzoomed size, so zooming
    // magnifies the comb instead of reflowing it into a different cluster.
    var maxCols: Int = 6
    // Viewport width, used to centre a comb narrower than the window. The
    // layout cannot read it from the proposal: inside a two-axis ScrollView
    // the proposed width is unbounded.
    var containerWidth: CGFloat = 0

    // Balanced comb: every row is centered, so hex packing holds only when
    // adjacent row lengths differ by an odd number (that difference is what
    // produces the half-cell shift). Search the alternating long/short
    // patterns that sum to n and keep the cluster closest to square.
    func rowLengths(_ n: Int, maxCols: Int) -> [Int] {
        guard n > 1 else { return n == 1 ? [1] : [] }

        func aspectScore(_ rows: [Int]) -> Double {
            let width = Double(rows.max() ?? 1)
            let height = (Double(rows.count - 1) * 0.75 + 1) * 2 / 3.0.squareRoot()
            return abs(width - height)
        }

        var best: [Int] = [min(n, maxCols)]
        var bestScore = Double.infinity
        for long in 2...max(2, min(n, maxCols)) {
            for startLong in [false, true] {
                var rows: [Int] = []
                var remaining = n
                var isLong = startLong
                while remaining > 0 {
                    let ideal = isLong ? long : long - 1
                    if remaining <= ideal {
                        if remaining % 2 == ideal % 2 {
                            rows.append(remaining)
                        } else if ideal % 2 == 0, remaining >= 3 {
                            rows.append(remaining - 1) // even, then a lone odd cap
                            rows.append(1)
                        } else {
                            rows = [] // no parity-safe finish; discard
                        }
                        remaining = 0
                    } else {
                        rows.append(ideal)
                        remaining -= ideal
                    }
                    isLong.toggle()
                }
                if !rows.isEmpty, rows.reduce(0, +) == n,
                   aspectScore(rows) < bestScore {
                    best = rows
                    bestScore = aspectScore(rows)
                }
            }
        }
        return best
    }

    // Also drives the minimap, so both read the comb from one source.
    func positions(count: Int) -> (points: [CGPoint], size: CGSize) {
        let w = cellWidth + spacing
        let cellHeight = cellWidth * 2 / sqrt(3)
        let rowPitch = cellHeight * 0.75 + spacing * 0.85
        let rows = rowLengths(count, maxCols: maxCols)
        let contentWidth = max(0, CGFloat(rows.max() ?? 0) * w - spacing)
        let layoutWidth = max(contentWidth, containerWidth)

        var points: [CGPoint] = []
        for (rowIndex, length) in rows.enumerated() {
            let span = CGFloat(length) * w - spacing
            let startX = (layoutWidth - span) / 2 + cellWidth / 2
            for i in 0..<length {
                points.append(CGPoint(
                    x: startX + CGFloat(i) * w,
                    y: CGFloat(rowIndex) * rowPitch + cellHeight / 2))
            }
        }
        let height = rows.isEmpty
            ? 0 : CGFloat(rows.count - 1) * rowPitch + cellHeight
        return (points, CGSize(width: layoutWidth, height: height))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews,
                      cache: inout ()) -> CGSize {
        positions(count: subviews.count).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        let result = positions(count: subviews.count)
        for (subview, point) in zip(subviews, result.points) {
            subview.place(
                at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y),
                anchor: .center, proposal: .unspecified)
        }
    }
}

// MARK: - Comb sizing

enum Comb {
    static let baseCell: CGFloat = 176
    static let baseSpacing: CGFloat = 16
    static let padding: CGFloat = 20
    // The floor is low enough that fit can still fit a large comb into a short
    // window; at that size the comb reads as a map and you zoom back in.
    static let zoomRange: ClosedRange<Double> = 0.2...2.5
    static let fitCeiling: Double = 1.6

    // Columns the window can hold at unzoomed size. Fixing the shape here keeps
    // it stable while zooming. Before the first geometry callback the viewport
    // is zero, which would collapse the comb into one column, so assume a
    // typical window until the real width arrives.
    static func maxCols(viewportWidth: CGFloat) -> Int {
        let width = viewportWidth > 1 ? viewportWidth : 900
        return max(1, Int((width + baseSpacing) / (baseCell + baseSpacing)))
    }

    static func layout(count: Int, zoom: Double, viewport: CGSize)
        -> HoneycombLayout {
        HoneycombLayout(
            cellWidth: baseCell * zoom, spacing: baseSpacing * zoom,
            maxCols: maxCols(viewportWidth: viewport.width),
            containerWidth: max(0, viewport.width - padding * 2))
    }

    // Comb size with no centring slack, i.e. the space the hexes really need.
    static func contentSize(count: Int, zoom: Double,
                            viewportWidth: CGFloat) -> CGSize {
        HoneycombLayout(cellWidth: baseCell * zoom, spacing: baseSpacing * zoom,
                        maxCols: maxCols(viewportWidth: viewportWidth),
                        containerWidth: 0)
            .positions(count: count).size
    }

    // Row shape is fixed, so content size scales linearly with zoom and the
    // fitting zoom is exact arithmetic rather than a search.
    static func fitZoom(count: Int, viewport: CGSize) -> Double {
        let free = CGSize(width: viewport.width - padding * 2,
                          height: viewport.height - padding * 2)
        guard count > 0, free.width > 1, free.height > 1 else { return 1 }
        let size = contentSize(count: count, zoom: 1,
                               viewportWidth: viewport.width)
        guard size.width > 1, size.height > 1 else { return 1 }
        let fit = min(Double(free.width / size.width),
                      Double(free.height / size.height))
        return min(max(fit, Comb.zoomRange.lowerBound), fitCeiling)
    }
}

struct OrbButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.93 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.55),
                       value: configuration.isPressed)
    }
}

struct SessionOrb: View {
    let tile: SessionTile
    var diameter: CGFloat
    let focus: (SessionTile) -> Void
    let requestKill: (SessionTile) -> Void
    @State private var hovered = false
    @State private var showCard = false

    // Working sessions carry a brighter rim, which is what the removed pulse
    // used to signal, at no rendering cost.
    private var rim: (top: Double, bottom: Double, width: CGFloat) {
        if tile.focused { return (0.9, 0.5, 2.5) }
        if tile.status == "working" { return (0.8, 0.3, 2) }
        return (0.45, 0.08, 1)
    }

    var body: some View {
        let color = statusColor(tile.status)
        Button { focus(tile) } label: {
            ZStack {
                VStack(spacing: diameter * 0.035) {
                    statusIcon(tile.status)
                        .scaledToFit()
                        .foregroundStyle(color.gradient)
                        .frame(width: diameter * 0.19, height: diameter * 0.19)
                    Text(tile.name)
                        .font(.system(size: diameter * 0.105, weight: .bold,
                                      design: .rounded))
                        .lineLimit(1)
                    Text(tile.dir)
                        .font(.system(size: diameter * 0.078, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(tile.agent == "claude"
                         ? tile.status.uppercased()
                         : "\(tile.agent.uppercased()) · \(tile.status.uppercased())")
                        .font(.system(size: diameter * 0.062, weight: .heavy,
                                      design: .rounded))
                        .kerning(1.2)
                        .foregroundStyle(color)
                        .opacity(0.9)
                        .lineLimit(1)
                    if let host = tile.host {
                        Text(host.uppercased())
                            .font(.system(size: diameter * 0.05, weight: .semibold,
                                          design: .rounded))
                            .kerning(0.8)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                .padding(diameter * 0.13)
                .frame(width: diameter, height: diameter * 2 / sqrt(3))
                .glassEffect(
                    .regular.tint(color.opacity(0.30)).interactive(),
                    in: Hexagon(cornerRadius: diameter * 0.08))
                .overlay(
                    Hexagon(cornerRadius: diameter * 0.08)
                        .fill(color.opacity(hovered ? 0.14 : 0))
                        .allowsHitTesting(false)
                )
                .overlay(
                    Hexagon(cornerRadius: diameter * 0.08).stroke(
                        LinearGradient(
                            colors: [color.opacity(rim.top), color.opacity(rim.bottom)],
                            startPoint: .topLeading, endPoint: .bottomTrailing),
                        lineWidth: rim.width)
                )
                .shadow(color: color.opacity(hovered ? 0.45 : 0.22),
                        radius: hovered ? diameter * 0.14 : diameter * 0.07,
                        y: diameter * 0.03)
                .scaleEffect(hovered ? 1.06 : 1)
            }
            .contentShape(Hexagon(cornerRadius: diameter * 0.08))
        }
        .buttonStyle(OrbButtonStyle())
        .contextMenu {
            Button("Focus") { focus(tile) }
            if tile.pid != nil {
                Divider()
                Button("Kill Session…", role: .destructive) { requestKill(tile) }
            }
        }
        .onHover { over in
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                hovered = over
            }
            if !over { showCard = false }
        }
        .task(id: hovered) {
            guard hovered else { return }
            try? await Task.sleep(for: .milliseconds(150))
            if hovered { showCard = true }
        }
        .popover(isPresented: $showCard, arrowEdge: .bottom) {
            InfoCard(tile: tile)
        }
    }
}

struct InfoCard: View {
    let tile: SessionTile

    private var prettyModel: String? {
        guard let model = tile.model else { return nil }
        return model
            .replacingOccurrences(of: "claude-", with: "")
            .split(separator: "-")
            .map { $0.first!.uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    private var prettyPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return tile.cwd.replacingOccurrences(of: home, with: "~")
    }

    var body: some View {
        let color = statusColor(tile.status)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(color.gradient).frame(width: 9, height: 9)
                Text(tile.name)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                Spacer()
                Text(tile.status.uppercased())
                    .font(.system(size: 10, weight: .heavy, design: .rounded))
                    .kerning(1)
                    .foregroundStyle(color)
            }
            Divider()
            Grid(alignment: .leadingFirstTextBaseline,
                 horizontalSpacing: 14, verticalSpacing: 7) {
                row("Model", prettyModel ?? "—")
                row("Running in", tile.host ?? "—")
                row("Folder", prettyPath)
                row("Version", tile.version ?? "—")
                row("Started", tile.startedAt.map {
                    $0.formatted(.relative(presentation: .named)) } ?? "—")
                row("Agent", tile.agent.capitalized)
                row("PID", tile.pid.map(String.init) ?? "—")
            }
            if let tokens = tile.contextTokens {
                // Codex reports its window exactly. Claude does not, so there
                // the cap is inferred: over 190k means a 1M session.
                let cap = tile.contextWindow
                    ?? (tokens > 190_000 ? 1_000_000 : 200_000)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Context")
                            .font(.system(size: 11, weight: .semibold,
                                          design: .rounded))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(formatTokens(tokens)) / \(formatTokens(cap))")
                            .font(.system(size: 11, weight: .semibold,
                                          design: .rounded))
                            .monospacedDigit()
                    }
                    UsageBar(percent: Double(tokens) / Double(cap) * 100,
                             color: color, height: 5)
                }
            }
        }
        .padding(16)
        .frame(width: 280)
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            Text(value)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

struct CountCapsule: View {
    let status: String
    let count: Int

    var body: some View {
        let color = statusColor(status)
        HStack(spacing: 6) {
            Circle().fill(color.gradient).frame(width: 8, height: 8)
            Text("\(count)")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .monospacedDigit()
            Text(status)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .glassEffect(.regular.tint(color.opacity(0.18)), in: .capsule)
    }
}

struct ZoomControls: View {
    @Binding var zoom: Double
    let fit: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            button(Ph.minusBold, "Zoom out", .command, "-") {
                zoom = max(zoom / 1.25, Comb.zoomRange.lowerBound)
            }
            Button {
                withAnimation(.spring(duration: 0.35)) { zoom = 1 }
            } label: {
                Text("\(Int((zoom * 100).rounded()))%")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .frame(width: 40)
            }
            .buttonStyle(.plain)
            .help("Reset to 100%")
            button(Ph.plusBold, "Zoom in", .command, "=") {
                zoom = min(zoom * 1.25, Comb.zoomRange.upperBound)
            }
            Divider().frame(height: 14).padding(.horizontal, 2)
            button(Ph.cornersOutBold, "Fit to view", .command, "0", action: fit)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .glassEffect(.regular, in: .capsule)
    }

    private func button(_ icon: Image, _ label: String,
                        _ modifiers: EventModifiers, _ key: KeyEquivalent,
                        action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.spring(duration: 0.35)) { action() }
        } label: {
            icon.scaledToFit()
                .foregroundStyle(.secondary)
                .frame(width: 13, height: 13)
                .padding(5)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(key, modifiers: modifiers)
        .help(label)
    }
}

// Shows what is off-screen and jumps there. No timers: the viewport rect comes
// from scroll geometry events, and panning happens only while dragging.
struct Minimap: View {
    let tiles: [SessionTile]
    let layout: HoneycombLayout
    let visible: CGRect
    let contentSize: CGSize
    let scrollTo: (CGPoint) -> Void

    private let maxSide: CGFloat = 140

    var body: some View {
        // One uniform scale for both axes keeps the map a true miniature.
        let scale = min(maxSide / max(contentSize.width, 1),
                        maxSide / max(contentSize.height, 1))
        let mapSize = CGSize(width: contentSize.width * scale,
                             height: contentSize.height * scale)
        let points = layout.positions(count: tiles.count).points

        ZStack(alignment: .topLeading) {
            ForEach(Array(tiles.enumerated()), id: \.element.id) { index, tile in
                if index < points.count {
                    Hexagon(cornerRadius: 1)
                        .fill(statusColor(tile.status).opacity(0.9))
                        .frame(width: layout.cellWidth * scale,
                               height: layout.cellWidth * scale * 2 / sqrt(3))
                        .position(x: points[index].x * scale,
                                  y: points[index].y * scale)
                }
            }
            Rectangle()
                .strokeBorder(.primary.opacity(0.6), lineWidth: 1.5)
                .frame(width: min(mapSize.width, visible.width * scale),
                       height: min(mapSize.height, visible.height * scale))
                .offset(x: visible.minX * scale, y: visible.minY * scale)
        }
        .frame(width: mapSize.width, height: mapSize.height)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0).onChanged { value in
                scrollTo(CGPoint(
                    x: value.location.x / scale - visible.width / 2,
                    y: value.location.y / scale - visible.height / 2))
            }
        )
        .padding(10)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
    }
}

// Picker only takes Text/Image labels and drops modifiers on them, which let
// the 256pt native SVG render full size. Plain buttons respect the frame.
struct ViewModeToggle: View {
    @Binding var mode: ViewMode

    var body: some View {
        GlassEffectContainer(spacing: 4) {
            HStack(spacing: 4) {
                button(.orbs, Ph.hexagonBold)
                button(.table, Ph.listDashesBold)
            }
        }
    }

    private func button(_ target: ViewMode, _ icon: Image) -> some View {
        let selected = mode == target
        return Button {
            mode = target
        } label: {
            icon
                .scaledToFit()
                .foregroundStyle(selected ? AnyShapeStyle(Color.accentColor)
                                          : AnyShapeStyle(.secondary))
                .frame(width: 14, height: 14)
                .padding(7)
        }
        .buttonStyle(.plain)
        .glassEffect(
            .regular.tint(Color.accentColor.opacity(selected ? 0.28 : 0)),
            in: .capsule)
    }
}

struct AgentTabs: View {
    @Binding var selection: String // all | claude | codex
    let counts: [String: Int]

    var body: some View {
        HStack(spacing: 3) {
            tab("all", "All", counts.values.reduce(0, +))
            ForEach(["claude", "codex"], id: \.self) { agent in
                if let count = counts[agent], count > 0 {
                    tab(agent, agent.capitalized, count)
                }
            }
        }
        .padding(3)
        .glassEffect(.regular, in: .capsule)
    }

    private func tab(_ id: String, _ label: String, _ count: Int) -> some View {
        let selected = selection == id
        return Button {
            withAnimation(.spring(duration: 0.3)) { selection = id }
        } label: {
            HStack(spacing: 4) {
                Text(label)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                Text("\(count)")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .opacity(0.6)
            }
            .foregroundStyle(selected ? AnyShapeStyle(.primary)
                                      : AnyShapeStyle(.secondary))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .glassEffect(
                .regular.tint(Color.accentColor.opacity(selected ? 0.3 : 0)),
                in: .capsule)
        }
        .buttonStyle(.plain)
    }
}

struct SearchField: View {
    @Binding var query: String
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 5) {
            Ph.magnifyingGlassBold.scaledToFit()
                .foregroundStyle(.secondary)
                .frame(width: 11, height: 11)
            TextField("Filter", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .rounded))
                .focused($focused)
                .frame(width: 110)
                .onSubmit { focused = false }
            if !query.isEmpty {
                Button { query = "" } label: {
                    Ph.xBold.scaledToFit()
                        .foregroundStyle(.secondary)
                        .frame(width: 9, height: 9)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.escape, modifiers: [])
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .glassEffect(.regular, in: .capsule)
        .overlay {
            // Focus the field from anywhere without stealing a visible control.
            Button("") { focused = true }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
        }
    }
}

struct HeaderView: View {
    let tiles: [SessionTile]
    @Binding var mode: ViewMode
    @Binding var agentFilter: String
    @Binding var query: String
    let agentCounts: [String: Int]
    private static let order = ["working", "done", "blocked", "idle", "unknown"]

    var body: some View {
        HStack(spacing: 10) {
            Text("Hivemind")
                .font(.system(size: 20, weight: .bold, design: .rounded))
            if agentCounts.count > 1 {
                AgentTabs(selection: $agentFilter, counts: agentCounts)
            }
            Spacer()
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    ForEach(Self.order, id: \.self) { status in
                        let count = tiles.count { $0.status == status }
                        if count > 0 {
                            CountCapsule(status: status, count: count)
                        }
                    }
                }
            }
            ViewModeToggle(mode: $mode)
        }
        // Overlaid rather than placed in the row, so the field sits at the true
        // centre of the header instead of wherever the side groups leave it.
        .overlay { SearchField(query: $query) }
        .padding(.horizontal, 22)
        .padding(.top, 34) // keep clear of the traffic lights
    }
}

struct SessionTableView: View {
    let tiles: [SessionTile]
    let focus: (SessionTile) -> Void
    let requestKill: (SessionTile) -> Void
    @State private var selection = Set<SessionTile.ID>()

    var body: some View {
        Table(tiles, selection: $selection) {
            TableColumn("Status") { tile in
                HStack(spacing: 6) {
                    statusIcon(tile.status)
                        .scaledToFit()
                        .foregroundStyle(statusColor(tile.status))
                        .frame(width: 12, height: 12)
                    Text(tile.status.capitalized)
                        .foregroundStyle(statusColor(tile.status))
                        .fontWeight(.semibold)
                }
            }
            .width(min: 70, ideal: 84)
            TableColumn("Agent") { Text($0.agent.capitalized) }
                .width(min: 55, ideal: 62)
            TableColumn("Name") { Text($0.name).fontWeight(.semibold) }
            TableColumn("Folder") { Text($0.dir).foregroundStyle(.secondary) }
            TableColumn("Running in") { Text($0.host ?? "—") }
            TableColumn("Model") { Text($0.model ?? "—") }
            TableColumn("Context") { tile in
                Text(tile.contextTokens.map(formatTokens) ?? "—").monospacedDigit()
            }
            .width(min: 55, ideal: 65)
            TableColumn("Started") { tile in
                Text(tile.startedAt.map {
                    $0.formatted(.relative(presentation: .named)) } ?? "—")
                    .foregroundStyle(.secondary)
            }
        }
        .contextMenu(forSelectionType: SessionTile.ID.self) { ids in
            if let tile = tiles.first(where: { ids.contains($0.id) }) {
                Button("Focus") { focus(tile) }
                Divider()
                Button("Kill Session…", role: .destructive) { requestKill(tile) }
            }
        } primaryAction: { ids in
            if let tile = tiles.first(where: { ids.contains($0.id) }) {
                focus(tile)
            }
        }
        .scrollContentBackground(.hidden)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

// Explicit track and fill rather than ProgressView: a determinate linear
// ProgressView does not paint reliably inside a Button label, which is where
// the expanded usage widget lives.
struct UsageBar: View {
    let percent: Double
    let color: Color
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(color.gradient)
                    .frame(width: geo.size.width
                           * min(1, max(0, percent / 100)))
            }
        }
        .frame(height: height)
    }
}

func usageColor(_ percent: Double) -> Color {
    if percent >= 95 { return .red }
    if percent >= 80 { return .orange }
    return .green
}

struct UsageGauge: View {
    let limit: UsageLimit

    private var color: Color { usageColor(limit.percent) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(limit.label)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if limit.percent >= 80 {
                    Ph.warningFill
                        .scaledToFit()
                        .foregroundStyle(color)
                        .frame(width: 11, height: 11)
                }
                Text("\(limit.wholePercent)%")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(color)
            }
            UsageBar(percent: limit.percent, color: color)
            Text(limit.resetsAt.map {
                "resets \($0.formatted(.relative(presentation: .named)))" } ?? " ")
                .font(.system(size: 10, design: .rounded))
                .foregroundStyle(.tertiary)
        }
        .frame(minWidth: 130, maxWidth: 210)
    }
}

// Compact corner widget. The full gauges live on the stats page it opens.
struct UsagePanel: View {
    let limits: [UsageLimit]
    let open: () -> Void
    @State private var hovered = false

    @State private var expanded = false

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: expanded ? 11 : 5) {
                if expanded {
                    ForEach(limits) { UsageGauge(limit: $0) }
                    Divider()
                    HStack(spacing: 6) {
                        Ph.chartBarBold.scaledToFit()
                            .foregroundStyle(.secondary)
                            .frame(width: 11, height: 11)
                        Text("Open usage stats")
                            .font(.system(size: 11, weight: .semibold,
                                          design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(limits) { compactRow($0) }
                }
            }
            .padding(expanded ? 14 : 10)
            .frame(width: expanded ? 236 : nil, alignment: .leading)
            .glassEffect(.regular.interactive(),
                         in: .rect(cornerRadius: expanded ? 18 : 12))
            .opacity(hovered ? 1 : 0.82)
        }
        .buttonStyle(.plain)
        .onHover { over in
            hovered = over
            if !over { expanded = false }
        }
        .task(id: hovered) {
            guard hovered else { return }
            try? await Task.sleep(for: .milliseconds(120))
            if hovered { expanded = true }
        }
        // One-shot spring on hover, not a repeating animation, so it does not
        // hit the glass recomposition cost.
        .animation(.spring(response: 0.34, dampingFraction: 0.82), value: expanded)
        .help("Open usage stats")
    }

    private func compactRow(_ limit: UsageLimit) -> some View {
        let color = usageColor(limit.percent)
        return HStack(spacing: 6) {
            Text(limit.shortLabel)
                .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(width: 38, alignment: .leading)
                .lineLimit(1)
            UsageBar(percent: limit.percent, color: color, height: 4)
                .frame(width: 44)
            if limit.percent >= 80 {
                Ph.warningFill.scaledToFit()
                    .foregroundStyle(color)
                    .frame(width: 8, height: 8)
            }
            Text("\(limit.wholePercent)%")
                .font(.system(size: 9.5, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(color)
                .frame(width: 26, alignment: .trailing)
        }
    }
}

struct StatsView: View {
    let limits: [UsageLimit]
    @Environment(\.dismiss) private var dismiss
    @State private var points: [Stats.Point]?

    private var models: [String] {
        Array(Set((points ?? []).map(\.model))).sorted()
    }

    private var weekTotals: [(model: String, tokens: Int, output: Int)] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -6,
                                           to: Calendar.current.startOfDay(for: .now))!
        var totals: [String: (Int, Int)] = [:]
        for point in (points ?? []) where point.day >= cutoff {
            let previous = totals[point.model] ?? (0, 0)
            totals[point.model] = (previous.0 + point.tokens, previous.1 + point.output)
        }
        return totals.map { (Stats.prettyModel($0.key), $0.value.0, $0.value.1) }
            .sorted { $0.1 > $1.1 }
    }

    var body: some View {
        ZStack {
            MeshBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    if !limits.isEmpty {
                        card("Plan limits, live from your account") {
                            // Wraps instead of an HStack: the row outgrew the
                            // sheet and clipped once Codex added a gauge.
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160),
                                                         spacing: 20)],
                                      alignment: .leading, spacing: 14) {
                                ForEach(limits) { UsageGauge(limit: $0) }
                            }
                        }
                    }
                    card("Claude tokens per day by model, last 14 days") {
                        if let points, !points.isEmpty {
                            chart(points)
                        } else if points == nil {
                            ProgressView().frame(height: 200)
                                .frame(maxWidth: .infinity)
                        } else {
                            Text("No transcript data in the last 14 days")
                                .foregroundStyle(.secondary)
                                .frame(height: 200)
                        }
                    }
                    card("Last 7 days by model") {
                        Grid(alignment: .leading, horizontalSpacing: 20,
                             verticalSpacing: 8) {
                            GridRow {
                                Text("Model").gridColumnAlignment(.leading)
                                Text("Input + cache").gridColumnAlignment(.trailing)
                                Text("Output").gridColumnAlignment(.trailing)
                            }
                            .font(.system(size: 11, weight: .semibold,
                                          design: .rounded))
                            .foregroundStyle(.secondary)
                            Divider()
                            ForEach(weekTotals, id: \.model) { row in
                                GridRow {
                                    Text(row.model).fontWeight(.semibold)
                                    Text(formatTokens(row.tokens)).monospacedDigit()
                                    Text(formatTokens(row.output)).monospacedDigit()
                                }
                                .font(.system(size: 12, design: .rounded))
                            }
                        }
                    }
                    Text("Daily figures are counted from local transcripts. The "
                         + "plan percentages above are weighted per model by "
                         + "Anthropic, so raw tokens do not convert into them.")
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 4)
                }
                .padding(22)
            }
        }
        .frame(minWidth: 660, idealWidth: 780, minHeight: 580, idealHeight: 700)
        .task {
            let scanned = await Task.detached(priority: .userInitiated) {
                Stats.scan()
            }.value
            points = scanned
        }
    }

    private var header: some View {
        HStack {
            Text("Usage Stats")
                .font(.system(size: 22, weight: .bold, design: .rounded))
            Spacer()
            Button("Done") { dismiss() }
                .buttonStyle(.glass)
        }
    }

    private func chart(_ points: [Stats.Point]) -> some View {
        Chart(points) { point in
            BarMark(
                x: .value("Day", point.day, unit: .day),
                y: .value("Tokens", point.tokens)
            )
            .foregroundStyle(by: .value("Model", Stats.prettyModel(point.model)))
            .cornerRadius(3)
        }
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine()
                AxisValueLabel {
                    if let tokens = value.as(Int.self) {
                        Text(formatTokens(tokens))
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: 2)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.day().month(.abbreviated))
            }
        }
        .chartLegend(position: .bottom, spacing: 12)
        .frame(height: 240)
    }

    @ViewBuilder
    private func card<Content: View>(
        _ title: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
            content()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
    }
}

struct EmptyStateView: View {
    var query: String = ""

    var body: some View {
        let searching = !query.trimmingCharacters(in: .whitespaces).isEmpty
        VStack(spacing: 14) {
            (searching ? Ph.magnifyingGlassBold : Ph.moonStarsDuotone)
                .scaledToFit()
                .foregroundStyle(.secondary)
                .frame(width: 40, height: 40)
                .padding(36)
                .glassEffect(.regular, in: .circle)
            Text(searching ? "Nothing matches “\(query)”" : "No open sessions")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ContentView: View {
    @EnvironmentObject var model: Model
    @Namespace private var glassSpace
    @AppStorage("viewMode") private var mode: ViewMode = .orbs
    @State private var killTarget: SessionTile?
    @State private var confirmKill = false
    @State private var showStats = false
    @AppStorage("combZoom") private var zoom: Double = 1.0
    @State private var viewport: CGSize = .zero
    @State private var visible: CGRect = .zero
    @State private var contentSize: CGSize = .zero
    @State private var scroll = ScrollPosition()
    @State private var pinchStart: Double?
    @AppStorage("agentFilter") private var agentFilter: String = "all"

    @State private var query = ""

    private var tiles: [SessionTile] {
        let byAgent = agentFilter == "all"
            ? model.tiles
            : model.tiles.filter { $0.agent == agentFilter }
        let search = query.trimmingCharacters(in: .whitespaces)
        guard !search.isEmpty else { return byAgent }
        // Best matches first while filtering; alphabetical otherwise.
        return byAgent.compactMap { tile in
            tileScore(search, tile).map { (tile, $0) }
        }
        .sorted { $0.1 > $1.1 }
        .map(\.0)
    }

    var body: some View {
        ZStack {
            MeshBackground()
            VStack(spacing: 0) {
                HeaderView(tiles: tiles, mode: $mode, agentFilter: $agentFilter,
                           query: $query, agentCounts: model.agentCounts)
                Group {
                    if tiles.isEmpty {
                        EmptyStateView(query: query)
                    } else if mode == .table {
                        SessionTableView(tiles: tiles, focus: model.focus,
                                         requestKill: requestKill)
                    } else {
                        comb
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    if !model.usageLimits.isEmpty {
                        UsagePanel(limits: model.usageLimits) { showStats = true }
                            .padding(14)
                    }
                }
            }
        }
        .animation(.spring(duration: 0.5), value: model.tiles)
        .animation(.spring(duration: 0.5), value: model.usageLimits)
        // The header carries title, agent tabs, status counts and the view
        // toggle around a centred search field, which needs the room to not
        // collide with the side groups.
        .frame(minWidth: 820, minHeight: 360)
        .confirmationDialog(
            "Kill \(killTarget?.name ?? "session")?",
            isPresented: $confirmKill, presenting: killTarget
        ) { tile in
            if let pid = tile.pid {
                Button("Kill \(tile.name) (pid \(pid))", role: .destructive) {
                    model.terminate(tile)
                }
            }
        } message: { tile in
            Text("Sends SIGTERM to the claude process in \(tile.dir).")
        }
        .sheet(isPresented: $showStats) {
            StatsView(limits: model.usageLimits)
        }
    }

    private var comb: some View {
        let layout = Comb.layout(count: tiles.count, zoom: zoom,
                                 viewport: viewport)
        let cell = Comb.baseCell * zoom
        let overflows = contentSize.height > viewport.height + 1
            || contentSize.width > viewport.width + 1

        return ScrollView([.horizontal, .vertical]) {
            // spacing is the liquid-merge distance; keep it well under the comb
            // gap or hovered hexes melt into blobs
            GlassEffectContainer(spacing: min(4, Comb.baseSpacing * zoom * 0.25)) {
                layout {
                    ForEach(tiles) { tile in
                        SessionOrb(tile: tile, diameter: cell,
                                   focus: model.focus, requestKill: requestKill)
                            .glassEffectID(tile.id, in: glassSpace)
                    }
                }
                .padding(Comb.padding)
            }
        }
        .scrollPosition($scroll)
        .onGeometryChange(for: CGSize.self, of: \.size) { viewport = $0 }
        .onScrollGeometryChange(for: ScrollGeometry.self, of: { $0 }) { _, new in
            visible = new.visibleRect
            contentSize = new.contentSize
        }
        // A live pinch is bounded by the gesture, unlike a repeating animation,
        // so it is safe to track it frame by frame under the glass.
        .simultaneousGesture(
            MagnifyGesture()
                .onChanged { value in
                    let target = (pinchStart ?? zoom) * Double(value.magnification)
                    if pinchStart == nil { pinchStart = zoom }
                    zoom = min(max(target, Comb.zoomRange.lowerBound),
                               Comb.zoomRange.upperBound)
                }
                .onEnded { _ in pinchStart = nil }
        )
        .overlay(alignment: .bottomTrailing) {
            VStack(alignment: .trailing, spacing: 10) {
                if overflows {
                    Minimap(tiles: tiles, layout: layout, visible: visible,
                            contentSize: contentSize) { point in
                        scroll.scrollTo(point: point)
                    }
                }
                ZoomControls(zoom: $zoom, fit: fitToView)
            }
            .padding(14)
        }
        .onKeyPress { press in
            let step = CGSize(width: visible.width / 2, height: visible.height / 2)
            switch press.key {
            case .leftArrow: pan(dx: -step.width)
            case .rightArrow: pan(dx: step.width)
            case .upArrow: pan(dy: -step.height)
            case .downArrow: pan(dy: step.height)
            default: return .ignored
            }
            return .handled
        }
        .animation(.spring(duration: 0.35), value: zoom)
    }

    private func pan(dx: CGFloat = 0, dy: CGFloat = 0) {
        scroll.scrollTo(point: CGPoint(
            x: max(0, min(visible.minX + dx, contentSize.width - visible.width)),
            y: max(0, min(visible.minY + dy, contentSize.height - visible.height))))
    }

    private func fitToView() {
        guard viewport.width > 1 else { return }
        zoom = Comb.fitZoom(count: tiles.count, viewport: viewport)
        scroll.scrollTo(edge: .top)
    }

    private func requestKill(_ tile: SessionTile) {
        killTarget = tile
        confirmKill = true
    }
}

@main
struct HivemindApp: App {
    @StateObject private var model: Model

    init() {
        if CommandLine.arguments.contains("--dump") {
            let layout = HoneycombLayout(cellWidth: 100)
            for n in 1...40 {
                let rows = layout.rowLengths(n, maxCols: 6)
                precondition(rows.reduce(0, +) == n, "rowLengths(\(n)) sum broken")
                for (a, b) in zip(rows, rows.dropFirst()) {
                    precondition((a - b) % 2 != 0,
                                 "rowLengths(\(n)) parity broken: \(rows)")
                }
            }
            for name in Ph.names {
                guard let url = Ph.url(name), NSImage(contentsOf: url) != nil else {
                    fatalError("icon \(name).svg missing from app bundle")
                }
            }
            print("icons ok; \(Ph.names.count) phosphor svgs load")
            // Fit must fit, and must be the largest zoom that does.
            for count in [1, 3, 7, 12, 25, 40] {
                for viewport in [CGSize(width: 900, height: 500),
                                 CGSize(width: 600, height: 900),
                                 CGSize(width: 1600, height: 1000)] {
                    let zoom = Comb.fitZoom(count: count, viewport: viewport)
                    let free = CGSize(width: viewport.width - Comb.padding * 2,
                                      height: viewport.height - Comb.padding * 2)
                    let size = Comb.contentSize(count: count, zoom: zoom,
                                                viewportWidth: viewport.width)
                    let fits = size.width <= free.width + 0.5
                        && size.height <= free.height + 0.5
                    // Or it bottomed out: some combs cannot fit at any usable
                    // zoom, and then the minimap carries navigation.
                    precondition(
                        fits || zoom <= Comb.zoomRange.lowerBound + 0.001,
                        "fitZoom(\(count), \(viewport)) overflows: \(size)")
                    if zoom < Comb.fitCeiling - 0.001 {
                        let bigger = Comb.contentSize(
                            count: count, zoom: zoom * 1.05,
                            viewportWidth: viewport.width)
                        precondition(bigger.width > free.width
                            || bigger.height > free.height,
                            "fitZoom(\(count), \(viewport)) is not maximal")
                    }
                }
            }
            print("fit-to-view ok; 7 tiles in 900x500 ->",
                  String(format: "%.0f%%",
                         Comb.fitZoom(count: 7,
                                      viewport: CGSize(width: 900, height: 500)) * 100))
            print("honeycomb layout ok; 7 ->",
                  layout.rowLengths(7, maxCols: 6).map(String.init).joined(separator: ","))
            let points = Stats.scan()
            var byDay: [Date: Int] = [:]
            for point in points { byDay[point.day, default: 0] += point.tokens }
            for (day, tokens) in byDay.sorted(by: { $0.key < $1.key }).suffix(4) {
                print("stats\t\(day.formatted(date: .numeric, time: .omitted))"
                      + "\t\(formatTokens(tokens))")
            }
            precondition(fuzzyScore("wiz", "wizard-of-envs") != nil)
            precondition(fuzzyScore("wzenv", "wizard-of-envs") != nil,
                         "gapped subsequence must match")
            precondition(fuzzyScore("zzz", "wizard-of-envs") == nil,
                         "out-of-order characters must not match")
            precondition(fuzzyScore("", "anything") == 0, "empty query matches")
            precondition(fuzzyScore("toolong", "abc") == nil,
                         "query longer than candidate cannot match")
            // A prefix run must outrank the same letters scattered.
            let tight = fuzzyScore("diag", "diagrams")!
            let loose = fuzzyScore("diag", "dxixaxg")!
            precondition(tight > loose, "consecutive match must score higher")
            // Word starts count: "oe" should favour of-envs over a mid-word hit.
            precondition(fuzzyScore("oe", "of-envs")!
                         > fuzzyScore("oe", "codex-mode")!,
                         "word-boundary match must score higher")
            print("fuzzy ok; wiz->wizard-of-envs scores \(tight)")

            // Exercise the Codex rollout parser on a real main-session file.
            let codexFiles = Codex.recentFiles()
            for url in codexFiles {
                guard let meta = Codex.firstLine(url),
                      let cwd = meta["cwd"] as? String,
                      (meta["source"] as? [String: Any])?["subagent"] == nil
                else { continue }
                let info = Codex.info(cwd: cwd, files: codexFiles)
                print("codex-parse\t\((cwd as NSString).lastPathComponent)"
                      + "\t\(info.model ?? "-")"
                      + "\t\(info.tokens.map(formatTokens) ?? "-")"
                      + "\t\(info.contextWindow.map(formatTokens) ?? "-")")
                break
            }
            let semaphore = DispatchSemaphore(value: 0)
            // detached: init runs on the MainActor, and a plain Task would
            // inherit it and deadlock against semaphore.wait() below
            Task.detached {
                var limits = await Usage.fetch()
                limits.append(contentsOf:
                    Codex.planLimits(files: Codex.recentFiles(limit: 8)))
                for limit in limits {
                    print("usage\t\(limit.agent)\t\(limit.label)"
                          + "\t\(limit.wholePercent)%\t"
                          + (limit.resetsAt?.formatted() ?? "-"))
                }
                semaphore.signal()
            }
            semaphore.wait()
            for tile in Sessions.load() {
                print([tile.agent, tile.status, tile.name, tile.dir,
                       tile.host ?? "-", tile.model ?? "-",
                       tile.contextTokens.map(String.init) ?? "-",
                       tile.contextWindow.map(String.init) ?? "-",
                       tile.terminalId ?? "-"].joined(separator: "\t"))
            }
            exit(0)
        }
        _model = StateObject(wrappedValue: Model())
    }

    var body: some Scene {
        WindowGroup("Hivemind") {
            ContentView().environmentObject(model)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
    }
}
