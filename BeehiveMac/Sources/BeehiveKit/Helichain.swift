import CryptoKit
import Foundation

/// One block in the helichain ledger.
public struct Block: Codable {
    public var index: Int
    public var songId: String
    public var contentHash: String
    public var recordFile: String
    public var createdAt: String
    public var bpm: Double
    public var nFrames: Int
    public var durationS: Double
    public var prevHash: String
    public var blockHash: String
}

/// Append-only, hash-linked, analyse-once ledger of helix records.
/// Port of beehive/helichain.py (CryptoKit for SHA-256).
public final class Helichain {
    public let root: URL
    private let recordsDir: URL
    private let chainFile: URL
    private static let genesis = String(repeating: "0", count: 64)

    public init(root: URL) {
        self.root = root
        self.recordsDir = root.appendingPathComponent("records")
        self.chainFile = root.appendingPathComponent("chain.jsonl")
        try? FileManager.default.createDirectory(at: recordsDir, withIntermediateDirectories: true)
    }

    public func blocks() -> [Block] {
        guard let text = try? String(contentsOf: chainFile, encoding: .utf8) else { return [] }
        let dec = JSONDecoder()
        return text.split(separator: "\n").compactMap {
            guard let d = $0.data(using: .utf8) else { return nil }
            return try? dec.decode(Block.self, from: d)
        }
    }

    private static func blockHash(prev: String, content: String, index: Int) -> String {
        let s = "\(prev)\(content)\(index)"
        return SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Append a record as a new block; idempotent on content hash.
    @discardableResult
    public func add(_ record: HelixRecord) throws -> (block: Block, created: Bool) {
        let chash = record.meta.contentHash
        let existing = blocks()
        if let found = existing.first(where: { $0.contentHash == chash }) {
            return (found, false)
        }
        let index = existing.count
        let prev = existing.last?.blockHash ?? Helichain.genesis

        let recURL = recordsDir.appendingPathComponent("\(record.meta.songId).json")
        try record.save(to: recURL)

        let block = Block(
            index: index, songId: record.meta.songId, contentHash: chash,
            recordFile: "records/\(record.meta.songId).json",
            createdAt: record.meta.createdAt, bpm: record.meta.bpm,
            nFrames: record.meta.nFrames, durationS: record.meta.durationS,
            prevHash: prev,
            blockHash: Helichain.blockHash(prev: prev, content: chash, index: index))

        let line = String(data: try JSONEncoder().encode(block), encoding: .utf8)! + "\n"
        if let fh = try? FileHandle(forWritingTo: chainFile) {
            fh.seekToEndOfFile(); fh.write(line.data(using: .utf8)!); fh.closeFile()
        } else {
            try line.data(using: .utf8)!.write(to: chainFile)
        }
        return (block, true)
    }

    public func loadRecord(songId: String) throws -> HelixRecord {
        try HelixRecord.load(from: recordsDir.appendingPathComponent("\(songId).json"))
    }

    /// Re-derive the hash links; returns (ok, firstBadIndex?).
    public func verify() -> (ok: Bool, badIndex: Int?) {
        var prev = Helichain.genesis
        for b in blocks() {
            let expected = Helichain.blockHash(prev: prev, content: b.contentHash, index: b.index)
            if b.prevHash != prev || b.blockHash != expected { return (false, b.index) }
            prev = b.blockHash
        }
        return (true, nil)
    }
}
