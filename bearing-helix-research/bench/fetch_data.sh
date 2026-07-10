#!/usr/bin/env bash
# Fetch the public bearing corpora the runner binaries consume.
#
#   bench/fetch_data.sh ims     (~1.2 GB zip; NASA IMS run-to-failure)
#   bench/fetch_data.sh cwru    (~150 MB; representative CWRU .mat files)
#   bench/fetch_data.sh femto   (~2 GB git clone; FEMTO/PRONOSTIA)
#
# URLs rot. Checksums are NOT pinned — verify sizes and provenance before
# trusting a download. Everything lands under data/ (gitignored).
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p data

case "${1:-}" in
  ims)
    # NASA Prognostics Center of Excellence mirror (IMS = dataset 4, "Bearings").
    # The zip nests .rar/.7z archives: `brew install sevenzip` to unpack.
    # After unpacking: data/ims/1st_test, 2nd_test, 3rd_test (ASCII snapshots).
    curl -L -C - -o data/ims_bearings.zip \
      "https://phm-datasets.s3.amazonaws.com/NASA/4.+Bearings.zip"
    echo "unpack: unzip data/ims_bearings.zip -d data/ims && 7z x the inner archives"
    echo "then:   cargo run --release --bin run_ims -- data/ims/2nd_test"
    ;;
  cwru)
    # Case Western bearing data center. Representative set at 1772 rpm plus
    # the 1797 rpm healthy baseline; numbering per the CWRU table.
    mkdir -p data/cwru
    for f in 97 98 105 106 118 119 130 131 169 170 209 210; do
      curl -L -C - -o "data/cwru/${f}.mat" \
        "https://engineering.case.edu/sites/default/files/${f}.mat" || \
        echo "  ${f}.mat failed — fetch manually from the CWRU bearing data center page"
    done
    echo "then: cargo run --release --bin run_cwru -- data/cwru/98.mat data/cwru/106.mat data/cwru/131.mat --rpm 1772"
    ;;
  femto)
    # FEMTO-ST / PRONOSTIA (IEEE PHM 2012 challenge) community mirror.
    git clone --depth 1 \
      https://github.com/wkzs111/phm-ieee-2012-data-challenge-dataset data/femto
    echo "then: cargo run --release --bin run_femto -- data/femto/Learning_set/Bearing1_1"
    ;;
  *)
    echo "usage: bench/fetch_data.sh ims|cwru|femto" >&2
    exit 1
    ;;
esac
