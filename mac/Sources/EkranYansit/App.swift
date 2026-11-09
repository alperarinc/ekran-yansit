import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Durum + işler

@MainActor
final class Controller: ObservableObject {
    enum State: Equatable { case idle, connecting, running, failed(String) }
    @Published var state = State.idle
    let mirror = Mirror()
    private let d = UserDefaults.standard

    var tvIP: String { d.string(forKey: "tvIP") ?? "" }
    var adbPath: String { d.string(forKey: "adbPath") ?? NSHomeDirectory() + "/Library/Android/sdk/platform-tools/adb" }
    var isActive: Bool { state == .connecting || state == .running }

    init() {
        mirror.onStop = { [weak self] err in
            Task { @MainActor in self?.state = err.map { .failed($0) } ?? .idle }
        }
    }

    func toggle() { isActive ? mirror.stop() : start() }

    func start() {
        guard !tvIP.isEmpty else { state = .failed("Ayarlar sekmesinden TV IP adresini gir."); return }
        state = .connecting
        let o = MirrorOptions(extend: d.string(forKey: "mode") == "extend", height: d.integer(forKey: "height"),
                              fps: d.integer(forKey: "fps"), bitrateMbps: d.integer(forKey: "bitrate"))
        let ip = tvIP
        Task {
            // Alıcıyı TV'de aç (açıksa öne getirir); -W açılana kadar bekler
            _ = await adb(["shell", "am", "start", "-W", "-n", "com.alper.ekranyansit/.MainActivity"])
            try? await Task.sleep(for: .milliseconds(800)) // sunucu soketinin açılması için
            do {
                try await mirror.start(host: ip, options: o)
                if state == .connecting { state = .running }
            } catch {
                mirror.stop(error.localizedDescription)
            }
        }
    }

    /// TV'ye adb komutu (gerekirse önce bağlanır). Ana thread'i bloklamaz.
    func adb(_ args: [String]) async -> (status: Int32, output: String) {
        let (path, serial) = (adbPath, "\(tvIP):5555")
        return await Task.detached {
            if !run(path, ["devices"]).output.contains("\(serial)\tdevice") { run(path, ["connect", serial]) }
            return run(path, ["-s", serial] + args)
        }.value
    }
}

// MARK: - Uygulama

@main
struct EkranYansitApp: App {
    @StateObject private var c = Controller()

    init() {
        if CommandLine.arguments.contains("--selftest") { selfTest(); exit(0) }
        UserDefaults.standard.register(defaults: ["fps": 30, "height": 1080, "bitrate": 8, "mode": "mirror"])
    }

    var body: some Scene {
        Window("Ekran Yansıt", id: "main") {
            ContentView().environmentObject(c)
        }
        .defaultSize(width: 760, height: 480)

        MenuBarExtra {
            MenuContent().environmentObject(c)
        } label: {
            Image(systemName: c.isActive ? "tv.fill" : "tv")
        }
    }
}

struct MenuContent: View {
    @EnvironmentObject var c: Controller
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(c.isActive ? "Durdur" : "Yansıt") { c.toggle() }
        if case .failed(let e) = c.state { Text("⚠︎ " + e) }
        Divider()
        Button("Pencereyi aç") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Çıkış") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

struct ContentView: View {
    var body: some View {
        TabView {
            MirrorView().tabItem { Label("Yansıtma", systemImage: "tv") }
            FilesView().tabItem { Label("Dosyalar", systemImage: "folder") }
            SettingsView().tabItem { Label("Ayarlar", systemImage: "gearshape") }
        }
        .padding()
        .frame(minWidth: 640, minHeight: 420)
    }
}

// MARK: - Yansıtma sekmesi

struct MirrorView: View {
    @EnvironmentObject var c: Controller
    @AppStorage("mode") private var mode = "mirror"
    @AppStorage("height") private var height = 1080
    @AppStorage("fps") private var fps = 30

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: c.state == .running ? "tv.fill" : "tv")
                .font(.system(size: 72))
                .foregroundStyle(c.state == .running ? Color.accentColor : .secondary)
            Picker("", selection: $mode) {
                Text("Yansıt (aynı görüntü)").tag("mirror")
                Text("Genişlet (TV 2. ekran)").tag("extend")
            }
            .pickerStyle(.segmented)
            .frame(width: 360)
            .disabled(c.isActive)
            Text(statusText).foregroundStyle(statusColor).multilineTextAlignment(.center)
            Button(c.isActive ? "Durdur" : "Başlat") { c.toggle() }
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            Text("TV: \(c.tvIP.isEmpty ? "ayarlı değil" : c.tvIP) · \(String(height))p · \(String(fps)) fps")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    var statusText: String {
        switch c.state {
        case .idle: "Hazır"
        case .connecting: "TV'ye bağlanıyor…"
        case .running: mode == "extend"
            ? "TV ikinci ekran olarak bağlı. Sistem Ayarları › Ekranlar'dan konumunu ayarlayabilirsin."
            : "Yansıtılıyor"
        case .failed(let e): e
        }
    }

    var statusColor: Color {
        if case .failed = c.state { return .red }
        return .primary
    }
}

// MARK: - Dosyalar sekmesi

struct FilesView: View {
    @EnvironmentObject var c: Controller
    @State private var dir = "/sdcard/Download"
    @State private var entries: [String] = []
    @State private var selection: String?
    @State private var busy: String?
    @State private var message: String?
    @State private var dropTargeted = false

    var body: some View {
        HStack(spacing: 16) {
            // Mac → TV
            VStack(spacing: 10) {
                Image(systemName: "arrow.up.doc").font(.system(size: 40))
                Text("Mac'ten TV'ye göndermek için\ndosyaları buraya sürükle").multilineTextAlignment(.center)
                Text("Hedef: \(dir)").font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 12)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8]))
                .foregroundStyle(dropTargeted ? Color.accentColor : .secondary))
            .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
                for p in providers {
                    _ = p.loadObject(ofClass: URL.self) { url, _ in
                        if let url { Task { @MainActor in await push(url) } }
                    }
                }
                return true
            }

            // TV → Mac
            VStack(alignment: .leading) {
                HStack {
                    Button { open("..") } label: { Image(systemName: "chevron.up") }
                        .disabled(dir == "/sdcard" || dir == "/")
                        .help("Üst klasör")
                    Text(dir).lineLimit(1).truncationMode(.head)
                    Spacer()
                    Button { Task { await refresh() } } label: { Image(systemName: "arrow.clockwise") }.help("Yenile")
                }
                List(entries, id: \.self, selection: $selection) { e in
                    Label(e.hasSuffix("/") ? String(e.dropLast()) : e, systemImage: e.hasSuffix("/") ? "folder" : "doc")
                }
                .contextMenu(forSelectionType: String.self) { _ in } primaryAction: { sel in
                    if let e = sel.first { if e.hasSuffix("/") { open(e) } else { Task { await pull(e) } } }
                }
                HStack {
                    Button("Mac'e indir") { if let s = selection { Task { await pull(s) } } }
                        .disabled(selection == nil || busy != nil)
                    if let busy { ProgressView().controlSize(.small); Text(busy).lineLimit(1) }
                    else if let message { Text(message).foregroundStyle(.secondary).lineLimit(1) }
                }
            }
            .frame(maxWidth: .infinity)
        }
        .task { await refresh() }
    }

    func path(_ e: String) -> String { dir + "/" + (e.hasSuffix("/") ? String(e.dropLast()) : e) }

    func open(_ e: String) {
        dir = e == ".." ? (dir as NSString).deletingLastPathComponent : path(e)
        selection = nil
        Task { await refresh() }
    }

    func refresh() async {
        let r = await c.adb(["shell", "ls -p " + shellQuote(dir)])
        if r.status == 0 {
            entries = r.output.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
                .sorted { ($0.hasSuffix("/") ? 0 : 1, $0.lowercased()) < ($1.hasSuffix("/") ? 0 : 1, $1.lowercased()) }
            message = nil
        } else {
            entries = []
            message = "TV'ye ulaşılamadı: " + r.output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    func push(_ url: URL) async {
        busy = "Gönderiliyor: \(url.lastPathComponent)"
        let r = await c.adb(["push", url.path, dir + "/"])
        busy = nil
        message = r.status == 0 ? "✓ Gönderildi: \(url.lastPathComponent)" : "Gönderilemedi: \(r.output)"
        await refresh()
    }

    func pull(_ e: String) async {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        busy = "İndiriliyor: \(e)"
        let r = await c.adb(["pull", path(e), downloads.path])
        busy = nil
        if r.status == 0 {
            message = "✓ İndirilenler klasörüne kaydedildi"
            NSWorkspace.shared.activateFileViewerSelecting([downloads.appendingPathComponent(String(e.trimmingCharacters(in: ["/"])))])
        } else {
            message = "İndirilemedi: \(r.output)"
        }
    }
}

// MARK: - Ayarlar sekmesi

struct SettingsView: View {
    @AppStorage("tvIP") private var tvIP = ""
    @AppStorage("height") private var height = 1080
    @AppStorage("fps") private var fps = 30
    @AppStorage("bitrate") private var bitrate = 8

    var body: some View {
        Form {
            TextField("TV IP adresi", text: $tvIP, prompt: Text("192.168.1.50"))
            Picker("Çözünürlük", selection: $height) {
                Text("720p").tag(720)
                Text("1080p").tag(1080)
                Text("1440p").tag(1440)
                Text("4K (2160p)").tag(2160)
            }
            Picker("Kare hızı", selection: $fps) {
                Text("15 fps").tag(15)
                Text("30 fps").tag(30)
                Text("60 fps").tag(60)
            }
            LabeledContent("Kalite (bit hızı)") {
                HStack {
                    Slider(value: Binding(get: { Double(bitrate) }, set: { bitrate = Int($0) }), in: 2...30, step: 1)
                    Text("\(bitrate) Mbit/s").monospacedDigit().frame(width: 80, alignment: .trailing)
                }
            }
            Text("Değişiklikler bir sonraki yansıtmada geçerli olur. Takılma olursa önce bit hızını, sonra kare hızını düşür.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}
