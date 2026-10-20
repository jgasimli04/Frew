import Foundation

// Stage 3 (Metal) + Stage 4 (audio) land here once F1/F3 have returned a
// verdict — building the GPU path before the cheap falsifiers have run would
// be work spent on an architecture that may already be falsified.
enum Stage {
    static func run(url: URL) {
        print("Stage 3/4 not built yet — run `analyze` first.")
        exit(3)
    }
}
