import BeehiveKit
import SwiftUI
import UniformTypeIdentifiers

/// Single-flight + coalescing gate around `scripts/convert_to_bee.py`, shared
/// by the manual Prepare→USB flow and the background auto-convert watcher so
/// they can never spawn overlapping encoders on the same folder. An actor (not
/// `@MainActor`) so both call sites can `await` without racing.
///
/// At most two OS processes are ever chained (one running + one queued). A
/// caller arriving mid-run is NOT satisfied by that run — its trigger may not
/// have existed when that run started — it's chained onto a guaranteed fresh
/// re-run, so `prepare(to:)` never returns before a run that began after its
/// own invocation completes.
actor ConverterGate {
    static let shared = ConverterGate()
    private var runningTask: Task<Int32, Never>?
    private var nextTask: Task<Int32, Never>?

    func convert(root: URL, folder: URL) async -> Int32 {
        if let running = runningTask {
            if let queued = nextTask { return await queued.value }
            let queued = Task<Int32, Never> {
                _ = await running.value
                return await self.startRun(root: root, folder: folder)
            }
            nextTask = queued
            return await queued.value
        }
        return await startRun(root: root, folder: folder)
    }

    private func startRun(root: URL, folder: URL) async -> Int32 {
        let task = Task<Int32, Never> { await Self.spawn(root: root, folder: folder) }
        runningTask = task
        let code = await task.value
        runningTask = nil; nextTask = nil
        return code
    }

    private static func spawn(root: URL, folder: URL) async -> Int32 {
        await withCheckedContinuation { cont in
            let proc = Process()
            proc.executableURL = root.appendingPathComponent(".venv/bin/python")
            proc.arguments = [root.appendingPathComponent("scripts/convert_to_bee.py").path,
                              folder.path]
            proc.currentDirectoryURL = root
            do { try proc.run() } catch { cont.resume(returning: -1); return }
            proc.waitUntilExit()
            cont.resume(returning: proc.terminationStatus)
        }
    }
}

/// The library half of BeeDeck (BEEDECK_ROADMAP T6 direction): browse a music
/// folder, search it, load decks from it, and PREPARE → USB — every selected
/// track becomes/ships as `.bee` (converted through the Python authoritative
/// pipeline when missing, then byte-verified after the copy), plus a
/// `beedeck_index.jsonl` the decks can browse on another machine.
@MainActor
final class LibraryModel: ObservableObject {
    struct Row: Identifiable, Hashable {
        var id: URL { url }
        let url: URL
        let name: String
        let ext: String
        let isBee: Bool
        var bpm: Double?
        var duration: Double?
        var hasBeeSibling: Bool
    }

    @Published var folder: URL
    @Published var rows: [Row] = []
    @Published var search = ""
    @Published var selection = Set<URL>()
    @Published var busy = false
    @Published var progress = ""
    @Published var autoConvertEnabled = true
    @Published var converterUnavailable = false   // repoRoot() couldn't resolve
    @Published var lastError: String?

    static let audioExts: Set<String> = ["bee", "aiff", "aif", "wav", "flac", "mp3", "m4a", "mp4", "mov", "m4v"]
    /// The converter's own extension set (`scripts/convert_to_bee.py`) — a
    /// subset of `audioExts` (no mp4/mov/m4v). Auto-convert must filter by
    /// *this* set or it retries forever on video files that never grow a `.bee`.
    static let convertibleExts: Set<String> = ["aiff", "aif", "wav", "flac", "mp3", "m4a"]

    private var watchTimer: Timer?
    private var lastSeenNames: Set<String> = []
    private var converting = false
    private var repoRootWarned = false

    init() {
        folder = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop/Music")
        rescan()
        lastSeenNames = currentNames()
        watchTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.autoConvertTick() }
        }
    }

    // ---- background auto-convert (θ grid for every new file) ----------------

    private func currentNames() -> Set<String> {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil)) ?? []
        return Set(items.map(\.lastPathComponent))
    }

    /// Cheap no-op unless the folder's file set actually changed since the last
    /// tick; only then does it rescan + decide whether a conversion is due.
    private func autoConvertTick() {
        guard autoConvertEnabled, !converting else { return }
        let names = currentNames()
        guard names != lastSeenNames else { return }
        lastSeenNames = names
        rescan()
        let due = rows.contains {
            !$0.isBee && !$0.hasBeeSibling && Self.convertibleExts.contains($0.ext)
        }
        guard due else { return }
        startAutoConvert()
    }

    private func startAutoConvert() {
        guard let root = Self.repoRoot() else {
            if !repoRootWarned { repoRootWarned = true; converterUnavailable = true }
            return
        }
        converterUnavailable = false
        converting = true; busy = true
        progress = "auto-converting new files…"
        let folder = self.folder
        Task.detached(priority: .utility) { [weak self] in
            let code = await ConverterGate.shared.convert(root: root, folder: folder)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.converting = false; self.busy = false
                if code == 0 { self.progress = "auto-convert: up to date"; self.lastError = nil }
                else { self.lastError = "auto-convert failed (exit \(code)) — see console" }
                self.rescan()
                self.lastSeenNames = self.currentNames()   // count the new .bee siblings
            }
        }
    }

    var filtered: [Row] {
        search.isEmpty ? rows
            : rows.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    func rescan() {
        let dir = folder
        let items = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)) ?? []
        let listed = items
            .filter { Self.audioExts.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let beeStems = Set(listed.filter { $0.pathExtension.lowercased() == "bee" }
            .map { $0.deletingPathExtension().lastPathComponent })
        rows = listed.map { url in
            let ext = url.pathExtension.lowercased()
            let stem = url.deletingPathExtension().lastPathComponent
            return Row(url: url, name: stem, ext: ext, isBee: ext == "bee",
                       bpm: nil, duration: nil,
                       hasBeeSibling: ext != "bee" && beeStems.contains(stem))
        }
        enrichBees()
    }

    /// bpm + duration for `.bee` rows, off the main actor (meta only).
    private func enrichBees() {
        let bees = rows.filter(\.isBee).map(\.url)
        Task.detached(priority: .utility) { [weak self] in
            for url in bees {
                guard let bee = try? BeeFile(path: url.path) else { continue }
                let dur = Double(bee.frames) / bee.sampleRate
                let bpm = (try? bee.record())?.meta.bpm
                await MainActor.run { [weak self] in
                    guard let self, let i = self.rows.firstIndex(where: { $0.url == url }) else { return }
                    self.rows[i].bpm = bpm
                    self.rows[i].duration = dur
                }
            }
        }
    }

    func chooseFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.prompt = "Use as Library"
        if p.runModal() == .OK, let u = p.url { folder = u; rescan() }
    }

    // ---- PREPARE → USB (T6) -------------------------------------------------

    /// Repo root discovery: the venv + converter live beside the package.
    /// (`swift run` starts in BeehiveMac; the repo root is its parent.)
    nonisolated private static func repoRoot() -> URL? {
        var dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        for _ in 0..<6 {
            if FileManager.default.fileExists(
                atPath: dir.appendingPathComponent(".venv/bin/python").path),
               FileManager.default.fileExists(
                atPath: dir.appendingPathComponent("scripts/convert_to_bee.py").path) {
                return dir
            }
            dir.deleteLastPathComponent()
        }
        return nil
    }

    func prepare(to dest: URL) {
        let picked = rows.filter { selection.contains($0.url) }
        guard !picked.isEmpty else { return }
        busy = true
        progress = "preparing \(picked.count) track(s)…"
        let folder = folder
        Task.detached(priority: .userInitiated) { [weak self] in
            var report: [String] = []
            var indexLines: [String] = []
            let fm = FileManager.default

            // 1. anything without a .bee goes through the authoritative
            //    Python pipeline (analyse-once; idempotent; native-verified)
            let needsConvert = picked.contains { !$0.isBee && !$0.hasBeeSibling }
            if needsConvert {
                if let root = Self.repoRoot() {
                    await MainActor.run { [weak self] in self?.progress = "encoding .bee (Python authoritative)…" }
                    let code = await ConverterGate.shared.convert(root: root, folder: folder)
                    if code != 0 { report.append("converter exited \(code)") }
                } else {
                    report.append("no repo venv found — non-.bee tracks skipped")
                }
            }

            // 2. copy each track's .bee to the stick, byte-verified
            for row in picked {
                let bee = row.isBee ? row.url
                    : row.url.deletingPathExtension().appendingPathExtension("bee")
                guard fm.fileExists(atPath: bee.path) else {
                    report.append("missing .bee: \(row.name)")
                    continue
                }
                let out = dest.appendingPathComponent(bee.lastPathComponent)
                do {
                    if fm.fileExists(atPath: out.path) { try fm.removeItem(at: out) }
                    try fm.copyItem(at: bee, to: out)
                    let a = try Data(contentsOf: bee, options: .mappedIfSafe)
                    let b = try Data(contentsOf: out, options: .mappedIfSafe)
                    guard a == b else {
                        report.append("VERIFY FAILED: \(row.name)")
                        try? fm.removeItem(at: out)
                        continue
                    }
                    var entry = "{\"file\": \"\(out.lastPathComponent)\""
                    if let bpm = row.bpm { entry += String(format: ", \"bpm\": %.2f", bpm) }
                    entry += ", \"bytes\": \(a.count)}"
                    indexLines.append(entry)
                } catch {
                    report.append("copy failed: \(row.name) — \(error.localizedDescription)")
                }
                let done = indexLines.count
                await MainActor.run { [weak self] in self?.progress = "prepared \(done)/\(picked.count)…" }
            }

            // 3. the stick's own library index
            if !indexLines.isEmpty {
                let idx = dest.appendingPathComponent("beedeck_index.jsonl")
                try? indexLines.joined(separator: "\n").appending("\n")
                    .write(to: idx, atomically: true, encoding: .utf8)
            }

            let ok = indexLines.count
            let summary = report.isEmpty
                ? "prepared \(ok)/\(picked.count) → \(dest.lastPathComponent) (byte-verified + index)"
                : "prepared \(ok)/\(picked.count); " + report.joined(separator: " · ")
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.busy = false
                self.progress = summary
                self.rescan()
            }
        }
    }
}

// MARK: - the pane

struct LibraryPane: View {
    @EnvironmentObject var session: DeckSession
    @StateObject private var lib = LibraryModel()

    var body: some View {
        VStack(spacing: 6) {
            toolbar
            list
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: BD.radius).fill(BD.panel))
        .overlay(RoundedRectangle(cornerRadius: BD.radius).strokeBorder(BD.seam.opacity(0.5), lineWidth: 1))
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button { lib.chooseFolder() } label: {
                Label(lib.folder.lastPathComponent, systemImage: "folder")
            }
            Button { lib.rescan() } label: { Image(systemName: "arrow.clockwise") }
                .help("Rescan the folder")
            TextField("search", text: $lib.search)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 260)
            Text("\(lib.filtered.count) tracks").font(.caption).foregroundColor(.secondary)
            Spacer()
            if lib.busy { ProgressView().controlSize(.small) }
            if !lib.progress.isEmpty {
                Text(lib.progress).font(.caption).foregroundColor(.secondary).lineLimit(1)
            }
            if lib.converterUnavailable {
                Text("⚠︎ converter not found (.venv / scripts/convert_to_bee.py)")
                    .font(.caption).foregroundColor(.red).lineLimit(1)
            }
            if let err = lib.lastError {
                Text("⚠︎ \(err)").font(.caption).foregroundColor(.red).lineLimit(1)
            }
            Button {
                let p = NSOpenPanel()
                p.canChooseDirectories = true
                p.canChooseFiles = false
                p.directoryURL = URL(fileURLWithPath: "/Volumes")
                p.prompt = "Prepare Here"
                if p.runModal() == .OK, let dest = p.url { lib.prepare(to: dest) }
            } label: { Label("Prepare → USB", systemImage: "externaldrive.badge.checkmark") }
                .disabled(lib.selection.isEmpty || lib.busy)
                .help("Every selected track ships as .bee (converted when missing, byte-verified), plus a library index")
        }
        .buttonStyle(.bordered).controlSize(.small)
    }

    private var list: some View {
        List(lib.filtered, id: \.url, selection: $lib.selection) { row in
            HStack(spacing: 8) {
                Text(row.name).lineLimit(1)
                if row.isBee {
                    Text("bee").font(.caption2.monospaced()).foregroundColor(.black)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.yellow.opacity(0.85), in: Capsule())
                } else {
                    Text(row.ext).font(.caption2.monospaced()).foregroundColor(.secondary)
                    if row.hasBeeSibling {
                        Image(systemName: "checkmark.seal").font(.caption2)
                            .foregroundColor(.yellow.opacity(0.7))
                            .help("a .bee already exists next to this file")
                    }
                }
                Spacer()
                if let bpm = row.bpm {
                    Text(String(format: "%.1f", bpm)).font(.caption.monospaced())
                        .foregroundColor(.secondary).frame(width: 46, alignment: .trailing)
                }
                if let dur = row.duration {
                    Text(mmss(dur)).font(.caption.monospaced())
                        .foregroundColor(.secondary).frame(width: 40, alignment: .trailing)
                }
                Button("→A") { session.load(url: row.url, onto: 0) }
                    .buttonStyle(.bordered).controlSize(.mini).tint(.cyan)
                Button("→B") { session.load(url: row.url, onto: 1) }
                    .buttonStyle(.bordered).controlSize(.mini).tint(.orange)
            }
            .draggable(row.url)
            .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        .frame(minHeight: 120, idealHeight: 170)
    }
}

// MARK: - the θ dial: the helix angle, visibly driving the deck

/// One rotation of the needle = one musical bar, straight from the record's
/// α array (the same fact SYNC phase-locks on). No estimate, no animation
/// easing — if this needle and the music disagree, the math is wrong.
struct ThetaDial: View {
    let theta: Double?          // radians, nil = no helix record
    let accent: Color

    var body: some View {
        Canvas { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let r = min(size.width, size.height) / 2 - 2
            ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)),
                       with: .color(.white.opacity(theta == nil ? 0.12 : 0.35)), lineWidth: 1)
            // four beat ticks (B=4): the θ≡0 tick is the downbeat
            for k in 0..<4 {
                let a = Double(k) * .pi / 2 - .pi / 2
                let p1 = CGPoint(x: c.x + (r - 3) * cos(a), y: c.y + (r - 3) * sin(a))
                let p2 = CGPoint(x: c.x + r * cos(a), y: c.y + r * sin(a))
                ctx.stroke(Path { $0.move(to: p1); $0.addLine(to: p2) },
                           with: .color(.white.opacity(k == 0 ? 0.8 : 0.3)), lineWidth: k == 0 ? 2 : 1)
            }
            if let th = theta {
                let a = th - .pi / 2                     // downbeat at 12 o'clock
                let tip = CGPoint(x: c.x + (r - 4) * cos(a), y: c.y + (r - 4) * sin(a))
                ctx.stroke(Path { $0.move(to: c); $0.addLine(to: tip) },
                           with: .color(accent), lineWidth: 2)
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - 2, y: c.y - 2, width: 4, height: 4)),
                         with: .color(accent))
            }
        }
        .frame(width: 34, height: 34)
        .help("θ — the helix angle at the playhead; one turn = one bar. This IS the grid SYNC locks on.")
    }
}
