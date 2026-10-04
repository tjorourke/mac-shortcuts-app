// A Dock app whose panels and buttons come from commands.json (bundled by ./build.sh).
// Each panel has an optional status script, a list of commands and a log. See the README for the format.
// Build: ./build.sh
import SwiftUI
import AppKit

let home = FileManager.default.homeDirectoryForCurrentUser.path
let appLog = home + "/Library/Logs/mac-shortcuts-app.log"
let shellPATH = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:\(home)/.local/bin"
func expand(_ p: String) -> String { (p as NSString).expandingTildeInPath }

// MARK: config (commands.json)

struct Confirm: Decodable { let title: String; let message: String?; let button: String? }

struct Command: Decodable, Identifiable {
    var id: String { title }
    let title: String
    let detail: String?
    let symbol: String?
    let tint: String?
    let run: String
    let style: String?          // "button" (default) or "link"
    let wait: Bool?             // true: run in the app and refresh after; false: detached, notify when done
    let confirm: Confirm?
    let check: String?          // exit 0 shows a green dot (links only)
    let disableWhen: [String]?  // status states in which this is greyed out
    var isLink: Bool { style == "link" }
}

struct Panel: Decodable, Identifiable {
    var id: String { title }
    let title: String
    let symbol: String?
    let tint: String?
    let cwd: String?
    let status: String?         // prints one JSON object, see Status
    let log: String?
    let commands: [Command]
}

struct Config: Decodable {
    let title: String?
    let refreshSeconds: Double?
    let panels: [Panel]
}

// What a status script prints.
struct StatusAction: Decodable { let title: String; let run: String; let help: String? }
struct Status: Decodable {
    let state: String           // ok | hot | busy | warn | error | off
    let text: String
    let detail: String?
    let subtitle: String?
    let badge: String?
    let badgeCaption: String?
    let action: StatusAction?
}

func loadConfig() -> Config {
    let a = CommandLine.arguments
    let path = a.firstIndex(of: "--config").flatMap { a.count > $0 + 1 ? a[$0 + 1] : nil }
        ?? Bundle.main.path(forResource: "commands", ofType: "json")
    guard let path, let data = FileManager.default.contents(atPath: path) else {
        return Config(title: "No commands.json", refreshSeconds: nil, panels: [])
    }
    do { return try JSONDecoder().decode(Config.self, from: data) } catch {
        return Config(title: "commands.json: \(error)", refreshSeconds: nil, panels: [])
    }
}

func colour(_ name: String?) -> Color {
    switch name {
    case "green": .green; case "red": .red; case "orange": .orange; case "purple": .purple
    case "pink": .pink; case "yellow": .yellow; case "teal": .teal; case "indigo": .indigo
    case "mint": .mint; case "cyan": .cyan; case "brown": .brown; case "gray", "grey": .gray
    default: .blue
    }
}

func stateColour(_ s: Status?) -> Color {
    switch s?.state {
    case "ok": .green; case "hot": .pink; case "busy": .orange; case "warn": .yellow; case "error": .red
    default: .gray
    }
}

// MARK: running shell commands

private final class Capture: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()
    func append(_ d: Data) { lock.lock(); data.append(d); lock.unlock() }
    var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
}

func makeProcess(_ cmd: String, cwd: String?, env extra: [String: String] = [:]) -> Process {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/bash")
    p.arguments = ["-c", cmd]
    var env = ProcessInfo.processInfo.environment
    env["PATH"] = shellPATH
    extra.forEach { env[$0] = $1 }
    p.environment = env
    if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: expand(cwd)) }
    return p
}

/// Runs a command and returns its exit code and stdout. Reads as output arrives rather than at EOF,
/// so a child that keeps the pipe open (a backgrounded server) cannot hang the app.
func run(_ cmd: String, cwd: String?) async -> (code: Int32, out: String) {
    await withCheckedContinuation { cont in
        let p = makeProcess(cmd, cwd: cwd)
        let pipe = Pipe(), out = Capture()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { h in out.append(h.availableData) }
        p.terminationHandler = { proc in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
                pipe.fileHandleForReading.readabilityHandler = nil
                cont.resume(returning: (proc.terminationStatus, out.text.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
        }
        do { try p.run() } catch { cont.resume(returning: (-1, "")) }
    }
}

/// Runs a command with its output in appLog and a macOS notification when it ends.
/// The notification comes from the shell, so it still arrives if the window is closed meanwhile.
func runDetached(_ cmd: String, cwd: String?, panel: String, title: String, done: @escaping @Sendable (Int32) -> Void) {
    let wrapper = """
    { echo "$(date '+%F %T') > $LAB_PANEL / $LAB_TITLE: $LAB_CMD"; bash -c "$LAB_CMD"; } >>"$LAB_LOG" 2>&1
    rc=$?
    echo "$(date '+%F %T') < exit $rc" >>"$LAB_LOG"
    if [ $rc -eq 0 ]; then LAB_MSG="Done"; else LAB_MSG="Failed (exit $rc). See $LAB_LOG"; fi
    export LAB_MSG
    osascript -e 'display notification (system attribute "LAB_MSG") with title (system attribute "LAB_PANEL") subtitle (system attribute "LAB_TITLE") sound name "Glass"' >/dev/null 2>&1
    exit $rc
    """
    let p = makeProcess(wrapper, cwd: cwd, env: ["LAB_CMD": cmd, "LAB_LOG": appLog, "LAB_PANEL": panel, "LAB_TITLE": title])
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    p.terminationHandler = { done($0.terminationStatus) }
    do { try p.run() } catch { done(-1) }
}

func notify(_ title: String, _ subtitle: String, _ message: String) {
    let p = makeProcess(#"osascript -e 'display notification (system attribute "M") with title (system attribute "T") subtitle (system attribute "S")'"#,
                        cwd: nil, env: ["T": title, "S": subtitle, "M": message])
    try? p.run()
}

// MARK: model

@MainActor
final class PanelModel: ObservableObject, Identifiable {
    let panel: Panel
    nonisolated var id: String { panel.title }
    @Published var status: Status?
    @Published var statusError: String?
    @Published var loading = true
    @Published var running: Set<String> = []
    @Published var checks: [String: Bool] = [:]

    init(_ panel: Panel) { self.panel = panel; loading = panel.status != nil }

    func refresh() async {
        async let checked: [(String, Bool)] = withTaskGroup(of: (String, Bool).self) { g in
            for c in panel.commands { if let chk = c.check { g.addTask { (c.title, await run(chk, cwd: self.panel.cwd).code == 0) } } }
            return await g.reduce(into: []) { $0.append($1) }
        }
        if let cmd = panel.status {
            let (code, out) = await run(cmd, cwd: panel.cwd)
            if let s = try? JSONDecoder().decode(Status.self, from: Data(out.utf8)) {
                status = s; statusError = nil
            } else if status == nil {
                statusError = code == 0 ? "status script printed no JSON" : "status script failed (exit \(code))"
            }
        }
        loading = false
        for (k, v) in await checked { checks[k] = v }
    }

    func disabled(_ c: Command) -> Bool {
        if running.contains(c.title) { return true }
        guard let when = c.disableWhen, !when.isEmpty else { return false }
        if loading || status == nil { return panel.status != nil }
        return when.contains(status!.state)
    }

    func perform(_ c: Command) { exec(c.title, c.run, wait: c.wait ?? false) }
    func perform(_ a: StatusAction) { exec(a.title, a.run, wait: true) }

    private func exec(_ title: String, _ cmd: String, wait: Bool) {
        running.insert(title)
        if wait {
            Task {
                let (code, _) = await run(cmd, cwd: panel.cwd)
                if code != 0 { notify(panel.title, title, "Failed (exit \(code))") }
                try? await Task.sleep(for: .seconds(2))
                running.remove(title)
                await refresh()
            }
        } else {
            Task { await refresh() }
            runDetached(cmd, cwd: panel.cwd, panel: panel.title, title: title) { _ in
                Task { @MainActor in self.running.remove(title); await self.refresh() }
            }
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    let config: Config
    let panels: [PanelModel]
    init(_ config: Config) { self.config = config; panels = config.panels.map(PanelModel.init) }
    func refreshAll() async {
        await withTaskGroup(of: Void.self) { g in for p in panels { g.addTask { await p.refresh() } } }
    }
}

// MARK: views

struct ActionButton: View {
    let command: Command
    let busy: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: command.symbol ?? "terminal.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(colour(command.tint).gradient, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(command.title).font(.system(size: 13, weight: .semibold))
                    if let d = command.detail { Text(d).font(.system(size: 11)).foregroundStyle(.secondary) }
                }
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                else { Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary) }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(hover ? Color.primary.opacity(0.07) : Color.primary.opacity(0.035),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

struct LinkButton: View {
    let command: Command
    let busy: Bool
    let check: Bool?
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let check { Circle().fill(check ? Color.green : Color.red).frame(width: 7, height: 7) }
                else { Image(systemName: command.symbol ?? "link") }
                Text(busy ? "Working…" : command.title)
            }
            .font(.system(size: 12, weight: .medium)).lineLimit(1).fixedSize()
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color.primary.opacity(hover ? 0.09 : 0.05), in: Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(command.detail ?? command.run)
    }
}

struct CircleIcon: View {
    let symbol: String
    let help: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary).frame(width: 28, height: 28)
                .background(Color.primary.opacity(0.05), in: Circle())
        }
        .buttonStyle(.plain).help(help)
    }
}

struct PanelView: View {
    @ObservedObject var model: PanelModel
    @State private var confirming: Command?

    var panel: Panel { model.panel }
    var buttons: [Command] { panel.commands.filter { !$0.isLink } }
    var links: [Command] { panel.commands.filter(\.isLink) }

    func tap(_ c: Command) { if c.confirm != nil { confirming = c } else { model.perform(c) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: panel.symbol ?? "square.grid.2x2.fill")
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(colour(panel.tint).gradient, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(panel.title).font(.system(size: 15, weight: .bold))
                    if let sub = model.status?.subtitle {
                        Text(sub).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                if let a = model.status?.action {
                    let busy = model.running.contains(a.title)
                    Button { model.perform(a) } label: {
                        Text(busy ? "Waiting…" : a.title).lineLimit(1).fixedSize()
                            .font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 9).padding(.vertical, 4)
                            .background(Color.red.gradient, in: Capsule())
                    }
                    .buttonStyle(.plain).disabled(busy).help(a.help ?? a.run)
                }
                if let log = panel.log {
                    CircleIcon(symbol: "doc.text", help: "Open \(log)") { NSWorkspace.shared.open(URL(fileURLWithPath: expand(log))) }
                }
            }

            if panel.status != nil { statusCard }

            if !buttons.isEmpty {
                VStack(spacing: 6) {
                    ForEach(buttons) { c in
                        ActionButton(command: c, busy: model.running.contains(c.title)) { tap(c) }
                            .disabled(model.disabled(c))
                            .opacity(model.disabled(c) ? 0.5 : 1)
                    }
                }
            }

            if !links.isEmpty {
                HStack(spacing: 8) {
                    ForEach(links) { c in
                        LinkButton(command: c, busy: model.running.contains(c.title), check: c.check == nil ? nil : model.checks[c.title] ?? false) { tap(c) }
                            .disabled(model.disabled(c))
                    }
                    Spacer()
                }
            }
        }
        .alert(confirming?.confirm?.title ?? "", isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } })) {
            Button(confirming?.confirm?.button ?? "Run", role: .destructive) { if let c = confirming { model.perform(c) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirming?.confirm?.message ?? confirming?.run ?? "")
        }
    }

    var statusCard: some View {
        let c = stateColour(model.status)
        return HStack(spacing: 12) {
            Circle().fill(c).frame(width: 10, height: 10).shadow(color: c.opacity(0.7), radius: 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.loading ? "Checking…" : (model.status?.text ?? model.statusError ?? "Unknown"))
                    .font(.system(size: 14, weight: .semibold))
                if let d = model.status?.detail, !model.loading {
                    Text(d).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer()
            if let b = model.status?.badge, !b.isEmpty {
                VStack(alignment: .trailing, spacing: 0) {
                    Text(b).font(.system(size: 18, weight: .bold, design: .rounded)).monospacedDigit()
                    if let cap = model.status?.badgeCaption { Text(cap).font(.system(size: 10)).foregroundStyle(.secondary) }
                }
            }
        }
        .padding(12)
        .background(c.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(c.opacity(0.25)))
    }
}

struct ContentView: View {
    @ObservedObject var app: AppModel
    let timer: Timer.TimerPublisher

    init(app: AppModel) {
        self.app = app
        timer = Timer.publish(every: app.config.refreshSeconds ?? 20, on: .main, in: .common)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 28, height: 28)
                Text(app.config.title ?? "Lab").font(.system(size: 17, weight: .bold)).lineLimit(2)
                Spacer()
                CircleIcon(symbol: "terminal", help: "Open the log of commands run from here") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: appLog))
                }
                CircleIcon(symbol: "arrow.clockwise", help: "Refresh") { Task { await app.refreshAll() } }
            }
            ForEach(Array(app.panels.enumerated()), id: \.element.id) { i, p in
                if i > 0 { Divider() }
                PanelView(model: p)
            }
        }
        .padding(18)
        .frame(width: 400)
        .task { if !snapshotMode { await app.refreshAll() } }
        .onReceive(timer.autoconnect()) { _ in Task { await app.refreshAll() } }
    }
}

let snapshotMode = CommandLine.arguments.contains("--snapshot")

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // Layout check without clicking: EKSLab --snapshot <out.png> [dark] [--config file]
    // Runs every status script once, renders the window to a PNG and exits.
    @MainActor func applicationDidFinishLaunching(_ note: Notification) {
        if !FileManager.default.fileExists(atPath: appLog) { FileManager.default.createFile(atPath: appLog, contents: nil) }
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: "--snapshot"), a.count > i + 1 else { return }
        let app = AppModel(loadConfig())
        Task { @MainActor in
            await app.refreshAll()
            let dark = a.contains("dark")
            let view = ContentView(app: app)
                .background(dark ? Color(white: 0.15) : Color(white: 0.96))
                .environment(\.colorScheme, dark ? .dark : .light)
            let r = ImageRenderer(content: view)
            r.scale = 2
            if let img = r.nsImage, let tiff = img.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: a[i + 1]))
            }
            exit(0)
        }
    }
}

@main
struct EKSLabApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var app = AppModel(loadConfig())
    var body: some Scene {
        WindowGroup(app.config.title ?? "Lab") { ContentView(app: app) }
            .windowResizability(.contentSize)
            .windowStyle(.hiddenTitleBar)
    }
}
