// EKS Lab: a small window for starting and stopping an EKS lab cluster.
// Every action runs ~/.local/bin/eks-lab, which owns the AWS calls and notifications.
// Build: ./build.sh
import SwiftUI
import AppKit

let eks = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/eks-lab").path
let logPath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/eks-lab.log").path

func run(_ args: [String]) async -> String {
    await withCheckedContinuation { cont in
        let p = Process()
        p.executableURL = URL(fileURLWithPath: eks)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { _ in
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            cont.resume(returning: String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
        }
        do { try p.run() } catch { cont.resume(returning: "") }
    }
}

@MainActor
final class Lab: ObservableObject {
    @Published var platform = -1
    @Published var gpus = -1
    @Published var cost = ""
    @Published var busy = false
    @Published var needsLogin = false
    @Published var loading = true
    @Published var lastAction: String?
    @Published var signingIn = false
    @Published var cluster = "EKS"
    @Published var region = ""
    @Published var soloUI: URL?
    @Published var consoleURL: URL?
    @Published var consoleUp = false

    func loadInfo() async {
        let lines = await run(["info"]).split(separator: "\n").map(String.init)
        guard lines.count >= 4 else { return }
        cluster = lines[0]; region = lines[1]
        soloUI = URL(string: lines[2]); consoleURL = URL(string: lines[3])
    }
    @Published var openingConsole = false

    func openConsole() {
        openingConsole = true
        Task {
            _ = await run(["console"])
            openingConsole = false
            await refresh()
        }
    }

    func signIn() {
        signingIn = true
        Task {
            _ = await run(["login"])
            signingIn = false
            await refresh()
        }
    }

    func refresh() async {
        loading = platform < 0
        let out = await run(["state"])
        loading = false
        if out.isEmpty { return }
        if out.hasPrefix("login") { needsLogin = true; platform = 0; gpus = 0; cost = ""; consoleUp = out.hasSuffix(" 1"); return }
        needsLogin = false
        let parts = out.split(separator: " ").map(String.init)
        guard parts.count >= 4 else { return }
        consoleUp = parts.count > 4 && parts[4] == "1"
        platform = Int(parts[0]) ?? 0
        gpus = Int(parts[1]) ?? 0
        cost = parts[2]
        busy = parts[3] == "1"
    }

    func start(_ action: String, label: String) {
        lastAction = label
        busy = true
        Task {
            _ = await run([action, "--background"])
            try? await Task.sleep(for: .seconds(3))
            await refresh()
        }
    }
}

struct ActionButton: View {
    let title: String
    let detail: String
    let symbol: String
    let tint: Color
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(tint.gradient, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
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

struct ConnectionPill: View {
    @ObservedObject var lab: Lab
    var body: some View {
        let connected = !lab.needsLogin && !lab.loading
        HStack(spacing: 6) {
            Circle().fill(lab.loading ? Color.gray : (connected ? Color.green : Color.red))
                .frame(width: 8, height: 8)
                .shadow(color: (connected ? Color.green : Color.red).opacity(lab.loading ? 0 : 0.8), radius: 3)
            if lab.needsLogin {
                Button { lab.signIn() } label: {
                    Text(lab.signingIn ? "Waiting…" : "Sign in").lineLimit(1).fixedSize()
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(Color.red.gradient, in: Capsule())
                }
                .buttonStyle(.plain).disabled(lab.signingIn)
                .help("Runs aws sso login for the lab profile")
            } else {
                Text(lab.loading ? "Checking" : "Connected").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).lineLimit(1).fixedSize()
            }
        }
        .padding(.leading, 8).padding(.trailing, lab.needsLogin ? 3 : 10).padding(.vertical, 3)
        .background(Color.primary.opacity(0.05), in: Capsule())
    }
}

struct FooterLink: View {
    let title: String
    let symbol: String
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol).font(.system(size: 12, weight: .medium)).lineLimit(1).fixedSize()
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Color.primary.opacity(hover ? 0.09 : 0.05), in: Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

struct ContentView: View {
    @StateObject var lab: Lab
    @State private var confirmStop = false
    let timer = Timer.publish(every: 20, on: .main, in: .common).autoconnect()

    var statusColour: Color {
        if lab.needsLogin { return .red }
        if lab.busy { return .orange }
        if lab.gpus > 0 { return .pink }
        return lab.platform > 0 ? .green : .gray
    }
    var statusText: String {
        if lab.needsLogin { return "AWS login expired" }
        if lab.loading { return "Checking…" }
        if lab.busy { return "Working…" }
        if lab.gpus > 0 { return "Running with GPUs" }
        return lab.platform > 0 ? "Running" : "Stopped"
    }
    var statusDetail: String {
        if lab.needsLogin { return lab.signingIn ? "Finish the sign-in in your browser." : "Click Sign in at the top to open the AWS SSO login." }
        if lab.loading { return "Reading the node groups" }
        let p = lab.platform > 0 ? "\(lab.platform) platform nodes" : "no platform nodes"
        let g = lab.gpus > 0 ? "\(lab.gpus) GPUs" : "GPUs off"
        let extra = lab.busy ? (lab.lastAction.map { " · \($0)" } ?? " · start or stop in progress") : ""
        return "\(p), \(g)\(extra)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text("EKS lab").font(.system(size: 17, weight: .bold))
                    Text(lab.region.isEmpty ? lab.cluster : "\(lab.cluster) · \(lab.region)").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                }
                Spacer()
                ConnectionPill(lab: lab)
                Button { Task { await lab.refresh() } } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary).frame(width: 28, height: 28)
                        .background(Color.primary.opacity(0.06), in: Circle())
                }
                .buttonStyle(.plain).help("Refresh")
            }

            HStack(spacing: 12) {
                Circle().fill(statusColour).frame(width: 10, height: 10)
                    .shadow(color: statusColour.opacity(0.7), radius: 4)
                VStack(alignment: .leading, spacing: 2) {
                    Text(statusText).font(.system(size: 14, weight: .semibold))
                    Text(statusDetail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                if !lab.cost.isEmpty && !lab.needsLogin {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text("$\(lab.cost)").font(.system(size: 18, weight: .bold, design: .rounded)).monospacedDigit()
                        Text("per hour").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(12)
            .background(statusColour.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(statusColour.opacity(0.25)))

            VStack(spacing: 6) {
                ActionButton(title: "Start EKS", detail: "agentgateway and its UI · about 5 to 10 min",
                             symbol: "play.fill", tint: .green) { lab.start("up", label: "starting") }
                ActionButton(title: "Start with GPUs", detail: "Adds two g7e GPUs · about $12.60/hr",
                             symbol: "bolt.fill", tint: .purple) { lab.start("gpu-up", label: "starting with GPUs") }
                ActionButton(title: "Stop GPUs only", detail: "agentgateway and its UI keep running",
                             symbol: "bolt.slash.fill", tint: .orange) { lab.start("gpu-down", label: "stopping GPUs") }
                ActionButton(title: "Stop EKS", detail: "Every node to 0 · control plane stays",
                             symbol: "stop.fill", tint: .red) { confirmStop = true }
            }
            .disabled(lab.busy || lab.needsLogin)
            .opacity(lab.busy || lab.needsLogin ? 0.5 : 1)

            HStack(spacing: 8) {
                Button { lab.openConsole() } label: {
                    HStack(spacing: 6) {
                        Circle().fill(lab.consoleUp ? Color.green : Color.red).frame(width: 7, height: 7)
                        Text(lab.openingConsole ? "Starting…" : (lab.consoleUp ? "Demo console" : "Start console"))
                            .font(.system(size: 12, weight: .semibold)).lineLimit(1).fixedSize()
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Color.accentColor.opacity(0.14), in: Capsule())
                }
                .buttonStyle(.plain).disabled(lab.openingConsole)
                .help("Opens the demo console, starting it first if it is down")
                FooterLink(title: "agentgateway (EKS) UI", symbol: "safari") { if let u = lab.soloUI { NSWorkspace.shared.open(u) } }
                Spacer()
                Button { NSWorkspace.shared.open(URL(fileURLWithPath: logPath)) } label: {
                    Image(systemName: "doc.text").font(.system(size: 12, weight: .medium))
                        .frame(width: 28, height: 28)
                        .background(Color.primary.opacity(0.05), in: Circle())
                }
                .buttonStyle(.plain).help("Open the log")
            }
        }
        .padding(18)
        .frame(width: 400)
        .task { if !snapshotMode { await lab.loadInfo(); await lab.refresh() } }
        .onReceive(timer) { _ in Task { await lab.refresh() } }
        .alert("Stop every \(lab.cluster) node?", isPresented: $confirmStop) {
            Button("Stop", role: .destructive) { lab.start("down", label: "stopping") }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The agentgateway and its UI go offline until you start it again.")
        }
    }
}

let snapshotMode = CommandLine.arguments.contains("--snapshot")

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // eks-lab's own check: EKSLab --snapshot <out.png> <platform> <gpus> <cost> <busy> [dark]
    @MainActor func applicationDidFinishLaunching(_ note: Notification) {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: "--snapshot"), a.count > i + 5 else { return }
        let lab = Lab()
        lab.loading = false
        lab.needsLogin = a[i + 2] == "login"
        lab.signingIn = a[i + 2] == "login" && a[i + 5] == "1"
        lab.platform = Int(a[i + 2]) ?? 0
        lab.gpus = Int(a[i + 3]) ?? 0
        lab.cost = a[i + 4]
        lab.busy = !lab.needsLogin && a[i + 5] == "1"
        lab.consoleUp = !a.contains("console-down")
        lab.cluster = "model-routing"; lab.region = "eu-west-2"
        lab.lastAction = lab.busy ? "starting" : nil
        let dark = a.count > i + 6 && a[i + 6] == "dark"
        let view = ContentView(lab: lab)
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

@main
struct EKSLabApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        WindowGroup("EKS lab") { ContentView(lab: Lab()) }
            .windowResizability(.contentSize)
            .windowStyle(.hiddenTitleBar)
    }
}
