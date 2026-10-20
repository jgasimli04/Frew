import BeehiveKit
import Foundation

enum Stats {
    static func mean(_ x: [Double]) -> Double { x.isEmpty ? .nan : x.reduce(0, +) / Double(x.count) }

    static func std(_ x: [Double]) -> Double {
        guard x.count > 1 else { return 0 }
        let m = mean(x)
        return sqrt(x.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(x.count - 1))
    }

    static func median(_ x: [Double]) -> Double {
        guard !x.isEmpty else { return .nan }
        let s = x.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    /// Coefficient of variation, std/mean. Dimensionless, so it compares across
    /// bands whose periods differ by an order of magnitude.
    static func cov(_ x: [Double]) -> Double {
        let m = mean(x)
        return m == 0 ? .nan : std(x) / m
    }
}

enum Corpus {
    static let root = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Desktop/Music")

    /// Containers AVFoundation decodes through `Audio.load`.
    static let decodable: Set<String> = ["aiff", "aif", "wav", "caf", "mp3", "m4a", "flac", "aac", "alac"]

    struct Entry {
        let url: URL
        let label: String
    }

    /// Every file under the corpus root, split into rows and stated exclusions.
    /// Nothing is curated for looking better; `excluded` is printed verbatim.
    static func scan() -> (rows: [Entry], bee: [Entry], excluded: [(String, String)]) {
        var rows: [Entry] = [], bee: [Entry] = [], excluded: [(String, String)] = []
        let all = (FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL } ?? []).sorted { $0.path < $1.path }

        for url in all {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            if isDir.boolValue { continue }
            let ext = url.pathExtension.lowercased()
            let name = url.lastPathComponent
            if name == ".DS_Store" {
                excluded.append((name, "filesystem metadata, not audio"))
            } else if ext == "bee" {
                bee.append(Entry(url: url, label: label(for: url)))
            } else if decodable.contains(ext) {
                rows.append(Entry(url: url, label: label(for: url)))
            } else {
                excluded.append((name, "not an audio container (.\(ext))"))
            }
        }
        return (rows, bee, excluded)
    }

    /// Short label for the distance matrix, kept unique.
    static func label(for url: URL) -> String {
        var stem = url.deletingPathExtension().lastPathComponent
        stem = stem.replacingOccurrences(of: "_(Original Mix)", with: "")
        stem = stem.replacingOccurrences(of: "Effy - The Highest Level EP - ", with: "Effy/")
        if let range = stem.range(of: #"^\d+_"#, options: .regularExpression) {
            stem.removeSubrange(range)
        }
        return String(stem.prefix(26))
    }
}
