import Foundation

// Spike CLI. `analyze` runs the falsifiers that need no window (F1–F4);
// `play <file>` runs Stage 3 + Stage 4 and reports F5.
setvbuf(stdout, nil, _IOLBF, 0)

let args = Array(CommandLine.arguments.dropFirst())

func usage() -> Never {
    print("""
    deficit-spike — angle-deficit architecture spike (see RESULTS.md)

      analyze [--f2] [--f4]   F1, F3 (+ null, + .bee control), optionally F2, F4
      f4                      F4 only (pure geometry, no audio)
      play <audio file>       Stage 3 + 4: Metal stage with audio, reports F5
    """)
    exit(2)
}

switch args.first {
case "control":
    EstimatorCheck.run()

case "analyze":
    let norm: Periods.Norm = args.contains("--unbiased") ? .unbiased : .biased
    print("  autocorrelation normalisation: \(norm == .biased ? "biased (Tempo.swift convention)" : "unbiased")\n")
    let tracks = Falsifiers.loadCorpus(norm: norm)
    guard !tracks.isEmpty else {
        print("\nno track analysed; stopping — F1 cannot be evaluated")
        exit(1)
    }
    Falsifiers.f1(tracks)
    Falsifiers.f3(tracks)
    let within = Falsifiers.f3Null(norm: norm)
    let matched = Falsifiers.f3Matched(norm: norm)
    if !within.isEmpty, matched.isFinite {
        print(String(format: "\n  matched ratio (between first-halves / within-track): %.3f",
                     matched / Stats.median(within)))
    }
    Falsifiers.beeControl()
    if args.contains("--f2") { Falsifiers.f2() }
    if args.contains("--f4") { Falsifiers.f4() }

case "f4":
    Falsifiers.f4()

case "play":
    guard args.count > 1 else { usage() }
    let url = URL(fileURLWithPath: args[1])
    Stage.run(url: url)

default:
    usage()
}
