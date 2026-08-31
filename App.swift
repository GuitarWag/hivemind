import SwiftUI
import UserNotifications

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
    let agentSession: AgentSession
    let agentStatus: String
    let terminalId: String
    let focused: Bool
}

struct HerdrAgentList: Decodable {
    struct Result: Decodable { let agents: [HerdrAgent] }
    let result: Result
}

struct SessionTile: Identifiable, Equatable {
    let id: String // Claude sessionId
    let name: String
    let dir: String
    var status: String // idle | working | blocked | done | unknown
    let terminalId: String?
    let focused: Bool
    let pid: Int32
    let cwd: String
    let version: String?
    let startedAt: Date?
    let model: String?
    let contextTokens: Int?
    let host: String? // Ghostty, GoLand, WebStorm, ...
}

// MARK: - Subprocesses

@discardableResult
func runCommand(_ path: String, _ args: [String]) -> Data {
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
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return data
}

// MARK: - Herdr CLI

enum Herdr {
    static let binary: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            home + "/.local/bin/herdr",
            "/opt/homebrew/bin/herdr",
            "/usr/local/bin/herdr",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? "herdr"
    }()

    @discardableResult
    static func run(_ args: [String]) -> Data {
        runCommand(binary, args)
    }

    static func agents() -> [String: HerdrAgent] {
        let data = run(["agent", "list"])
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let list = try? decoder.decode(HerdrAgentList.self, from: data) else { return [:] }
        var map: [String: HerdrAgent] = [:]
        for agent in list.result.agents {
            map[agent.agentSession.value] = agent
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

    // Climb the parent chain until an .app bundle or a known host shows up.
    static func host(of pid: Int32,
                     table: [Int32: (ppid: Int32, comm: String)]) -> String? {
        var current = pid
        for _ in 0..<15 {
            guard let entry = table[current] else { return nil }
            let comm = entry.comm
            if let range = comm.range(of: ".app/") {
                let bundle = comm[..<range.lowerBound]
                return bundle.split(separator: "/").last.map(String.init)
            }
            let base = (comm as NSString).lastPathComponent
            // ponytail: herdr is a detached server, its ancestry ends at launchd.
            // This user's herdr renders in Ghostty (see dev-setup repo).
            if base == "herdr" { return "Ghostty · herdr" }
            if ["tmux", "zellij", "screen"].contains(base) { return base }
            current = entry.ppid
            if current <= 1 { return nil }
        }
        return nil
    }
}

// MARK: - Transcript info (model, context size)

enum Transcript {
    // ~/.claude/projects/<cwd with / and . replaced by -> / <sessionId>.jsonl
    static func path(sessionId: String, cwd: String) -> String {
        let slug = String(cwd.map { "/.".contains($0) ? "-" : $0 })
        return FileManager.default.homeDirectoryForCurrentUser.path
            + "/.claude/projects/\(slug)/\(sessionId).jsonl"
    }

    // Read the tail and take model + usage from the last assistant message.
    static func info(sessionId: String, cwd: String) -> (model: String?, tokens: Int?) {
        guard let fh = FileHandle(forReadingAtPath: path(sessionId: sessionId, cwd: cwd))
        else { return (nil, nil) }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        let tailLength: UInt64 = 128 * 1024
        try? fh.seek(toOffset: size > tailLength ? size - tailLength : 0)
        guard let data = try? fh.readToEnd(),
              let text = String(data: data, encoding: .utf8)
        else { return (nil, nil) }

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

    var id: String { kind + (scope?.model?.displayName ?? "") }

    var label: String {
        switch kind {
        case "session": return "Session"
        case "weekly_all": return "Week · all models"
        case "weekly_scoped":
            return "Week · \(scope?.model?.displayName ?? "model")"
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

// MARK: - Session loading

enum Sessions {
    static let dir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/sessions")

    static func load() -> [SessionTile] {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        let herdr = Herdr.agents()
        let processes = Hosts.processTable()

        var tiles: [SessionTile] = []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let session = try? decoder.decode(ClaudeSessionFile.self, from: data)
            else { continue }
            // A session file can outlive its process. Keep only live pids.
            guard kill(session.pid, 0) == 0 else { continue }

            let agent = herdr[session.sessionId]
            let status = agent?.agentStatus
                ?? session.status.map { $0 == "busy" ? "working" : $0 }
                ?? "unknown"
            let transcript = Transcript.info(
                sessionId: session.sessionId, cwd: session.cwd)
            tiles.append(SessionTile(
                id: session.sessionId,
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
                host: Hosts.host(of: session.pid, table: processes)
            ))
        }
        return tiles.sorted { $0.name < $1.name }
    }
}

// MARK: - Model

@MainActor
final class Model: ObservableObject {
    @Published var tiles: [SessionTile] = []
    @Published var usageLimits: [UsageLimit] = []
    private var timer: Timer?
    private var usageTimer: Timer?
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
        usageTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) {
            [weak self] _ in self?.refreshUsage()
        }
    }

    nonisolated func refreshUsage() {
        Task.detached(priority: .utility) {
            let limits = await Usage.fetch()
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
            content.title = "Claude usage at \(Int(limit.percent))%"
            content.body = limit.label + (limit.resetsAt.map {
                ", resets \($0.formatted(.relative(presentation: .named)))" } ?? "")
            content.sound = .default
            UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: key, content: content, trigger: nil))
        }
    }

    nonisolated func refresh() {
        Task.detached(priority: .utility) {
            let loaded = Sessions.load()
            await MainActor.run { [weak self] in
                guard let self else { return }
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
        Darwin.kill(tile.pid, SIGTERM)
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
            await MainActor.run {
                let workspace = NSWorkspace.shared
                if let url = workspace.urlForApplication(
                    withBundleIdentifier: "com.mitchellh.ghostty") {
                    let config = NSWorkspace.OpenConfiguration()
                    config.activates = true
                    workspace.openApplication(at: url, configuration: config)
                }
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
    n >= 1000 ? String(format: "%.0fk", Double(n) / 1000) : "\(n)"
}

enum ViewMode: String, CaseIterable, Identifiable {
    case orbs, table
    var id: String { rawValue }
}

func statusSymbol(_ status: String) -> String {
    switch status {
    case "idle": return "moon.zzz.fill"
    case "working": return "bolt.fill"
    case "blocked": return "exclamationmark.triangle.fill"
    case "done": return "checkmark"
    default: return "questionmark"
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

// ponytail: any repeating SwiftUI animation under glassEffect recomposites the
// whole window (~10-15% CPU). A periodic short fade keeps the redraw duty
// cycle low. Re-check if glass compositing gets cheaper in a later macOS.
struct WorkingBlink: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        if active {
            TimelineView(.periodic(from: .now, by: 1.2)) { context in
                let on = Int(
                    context.date.timeIntervalSinceReferenceDate / 1.2) % 2 == 0
                content
                    .opacity(on ? 1 : 0.45)
                    .animation(.easeInOut(duration: 0.35), value: on)
            }
        } else {
            content
        }
    }
}

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

    private func positions(count: Int, width: CGFloat)
        -> (points: [CGPoint], size: CGSize) {
        let w = cellWidth + spacing
        let cellHeight = cellWidth * 2 / sqrt(3)
        let rowPitch = cellHeight * 0.75 + spacing * 0.85
        let capacity = max(1, Int((width + spacing) / w))
        let rows = rowLengths(count, maxCols: capacity)

        var points: [CGPoint] = []
        for (rowIndex, length) in rows.enumerated() {
            let span = CGFloat(length) * w - spacing
            let startX = (width - span) / 2 + cellWidth / 2
            for i in 0..<length {
                points.append(CGPoint(
                    x: startX + CGFloat(i) * w,
                    y: CGFloat(rowIndex) * rowPitch + cellHeight / 2))
            }
        }
        let height = rows.isEmpty
            ? 0 : CGFloat(rows.count - 1) * rowPitch + cellHeight
        return (points, CGSize(width: width, height: height))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews,
                      cache: inout ()) -> CGSize {
        positions(count: subviews.count, width: proposal.width ?? 600).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        let result = positions(count: subviews.count, width: bounds.width)
        for (subview, point) in zip(subviews, result.points) {
            subview.place(
                at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y),
                anchor: .center, proposal: .unspecified)
        }
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

    var body: some View {
        let color = statusColor(tile.status)
        Button { focus(tile) } label: {
            ZStack {
                VStack(spacing: diameter * 0.035) {
                    Image(systemName: statusSymbol(tile.status))
                        .font(.system(size: diameter * 0.16, weight: .semibold))
                        .foregroundStyle(color.gradient)
                        .symbolRenderingMode(.hierarchical)
                        .modifier(WorkingBlink(active: tile.status == "working"))
                    Text(tile.name)
                        .font(.system(size: diameter * 0.105, weight: .bold,
                                      design: .rounded))
                        .lineLimit(1)
                    Text(tile.dir)
                        .font(.system(size: diameter * 0.078, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(tile.status.uppercased())
                        .font(.system(size: diameter * 0.062, weight: .heavy,
                                      design: .rounded))
                        .kerning(1.2)
                        .foregroundStyle(color)
                        .opacity(0.9)
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
                    in: Hexagon())
                .overlay(
                    Hexagon().fill(color.opacity(hovered ? 0.14 : 0))
                        .allowsHitTesting(false)
                )
                .overlay(
                    Hexagon().stroke(
                        LinearGradient(
                            colors: [color.opacity(tile.focused ? 0.9 : 0.45),
                                     color.opacity(tile.focused ? 0.5 : 0.08)],
                            startPoint: .topLeading, endPoint: .bottomTrailing),
                        lineWidth: tile.focused ? 2.5 : 1)
                )
                .shadow(color: color.opacity(hovered ? 0.45 : 0.22),
                        radius: hovered ? diameter * 0.14 : diameter * 0.07,
                        y: diameter * 0.03)
                .scaleEffect(hovered ? 1.06 : 1)
            }
            .contentShape(Hexagon())
        }
        .buttonStyle(OrbButtonStyle())
        .contextMenu {
            Button("Focus") { focus(tile) }
            Divider()
            Button("Kill Session…", role: .destructive) { requestKill(tile) }
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
                row("PID", "\(tile.pid)")
            }
            if let tokens = tile.contextTokens {
                // ponytail: max context is a guess (>190k means a 1M session);
                // the session file does not record the real limit.
                let cap = tokens > 190_000 ? 1_000_000 : 200_000
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
                    ProgressView(value: min(1, Double(tokens) / Double(cap)))
                        .tint(color)
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

struct HeaderView: View {
    let tiles: [SessionTile]
    @Binding var mode: ViewMode
    private static let order = ["working", "done", "blocked", "idle", "unknown"]

    var body: some View {
        HStack(spacing: 10) {
            Text("Claude Sessions")
                .font(.system(size: 20, weight: .bold, design: .rounded))
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
            Picker("View", selection: $mode) {
                Image(systemName: "circle.hexagongrid.fill").tag(ViewMode.orbs)
                Image(systemName: "list.bullet").tag(ViewMode.table)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 88)
        }
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
                    Circle().fill(statusColor(tile.status).gradient)
                        .frame(width: 8, height: 8)
                    Text(tile.status.capitalized)
                        .foregroundStyle(statusColor(tile.status))
                        .fontWeight(.semibold)
                }
            }
            .width(min: 70, ideal: 84)
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

struct UsageGauge: View {
    let limit: UsageLimit

    private var color: Color {
        if limit.percent >= 95 { return .red }
        if limit.percent >= 80 { return .orange }
        return .green
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(limit.label)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if limit.percent >= 80 {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(color)
                }
                Text("\(Int(limit.percent))%")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(color)
            }
            ProgressView(value: min(1, limit.percent / 100))
                .tint(color)
            Text(limit.resetsAt.map {
                "resets \($0.formatted(.relative(presentation: .named)))" } ?? " ")
                .font(.system(size: 10, design: .rounded))
                .foregroundStyle(.tertiary)
        }
        .frame(minWidth: 130, maxWidth: 210)
    }
}

struct UsagePanel: View {
    let limits: [UsageLimit]

    var body: some View {
        HStack(spacing: 22) {
            ForEach(limits) { UsageGauge(limit: $0) }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
        .padding(.horizontal, 22)
        .padding(.bottom, 14)
    }
}

struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "moon.stars.fill")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 110, height: 110)
                .glassEffect(.regular, in: .circle)
            Text("No open Claude sessions")
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
    private let diameter: CGFloat = 176

    var body: some View {
        ZStack {
            MeshBackground()
            VStack(spacing: 0) {
                HeaderView(tiles: model.tiles, mode: $mode)
                if model.tiles.isEmpty {
                    EmptyStateView()
                } else if mode == .table {
                    SessionTableView(tiles: model.tiles, focus: model.focus,
                                     requestKill: requestKill)
                } else {
                    ScrollView {
                        // spacing is the liquid-merge distance; keep it well
                        // under the comb gap or hovered hexes melt into blobs
                        GlassEffectContainer(spacing: 4) {
                            HoneycombLayout(cellWidth: diameter) {
                                ForEach(model.tiles) { tile in
                                    SessionOrb(tile: tile, diameter: diameter,
                                               focus: model.focus,
                                               requestKill: requestKill)
                                        .glassEffectID(tile.id, in: glassSpace)
                                }
                            }
                            .padding(.horizontal, 22)
                            .padding(.vertical, 20)
                        }
                    }
                }
                if !model.usageLimits.isEmpty {
                    UsagePanel(limits: model.usageLimits)
                }
            }
        }
        .animation(.spring(duration: 0.5), value: model.tiles)
        .animation(.spring(duration: 0.5), value: model.usageLimits)
        .frame(minWidth: 480, minHeight: 340)
        .confirmationDialog(
            "Kill \(killTarget?.name ?? "session")?",
            isPresented: $confirmKill, presenting: killTarget
        ) { tile in
            Button("Kill \(tile.name) (pid \(tile.pid))", role: .destructive) {
                model.terminate(tile)
            }
        } message: { tile in
            Text("Sends SIGTERM to the claude process in \(tile.dir).")
        }
    }

    private func requestKill(_ tile: SessionTile) {
        killTarget = tile
        confirmKill = true
    }
}

@main
struct ClaudeSessionsApp: App {
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
            print("honeycomb layout ok; 7 ->",
                  layout.rowLengths(7, maxCols: 6).map(String.init).joined(separator: ","))
            let semaphore = DispatchSemaphore(value: 0)
            // detached: init runs on the MainActor, and a plain Task would
            // inherit it and deadlock against semaphore.wait() below
            Task.detached {
                for limit in await Usage.fetch() {
                    print("usage\t\(limit.label)\t\(Int(limit.percent))%\t"
                          + (limit.resetsAt?.formatted() ?? "-"))
                }
                semaphore.signal()
            }
            semaphore.wait()
            for tile in Sessions.load() {
                print([tile.status, tile.name, tile.dir, tile.host ?? "-",
                       tile.model ?? "-", tile.contextTokens.map(String.init) ?? "-",
                       tile.terminalId ?? "-"].joined(separator: "\t"))
            }
            exit(0)
        }
        _model = StateObject(wrappedValue: Model())
    }

    var body: some Scene {
        WindowGroup("Claude Sessions") {
            ContentView().environmentObject(model)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
    }
}
