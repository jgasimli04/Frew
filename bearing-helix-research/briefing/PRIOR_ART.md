# Prior art — what is old, what is adjacent, what was not found

Standing rule: no novelty claim without a scan, and the scan's scope stated.
Two scans inform this file: the remote session's (2026-07-06, commit 6fe0551,
unreachable — inherited, not re-verified) and a fresh web scan on 2026-07-07
(sources below). Training-knowledge citations are marked (k).

## Old — the analysis practice this stands on (decades, settled)

- **Time-synchronous averaging** of rotating-machine vibration: McFadden's
  formulation and successors (k; e.g. "Time Domain Synchronous Moving Average"
  continues the line — [researchgate](https://www.researchgate.net/publication/334379623_Time_Domain_Synchronous_Moving_Average_and_its_Application_to_Gear_Fault_Detection)).
  TSA + residual ("difference signal") for gear/bearing diagnosis is textbook;
  TSA on angular-resampled signals with AR-model residual extraction appears
  throughout the condition-monitoring literature
  ([science.gov survey page](https://www.science.gov/topicpages/v/vibration+condition+monitoring),
  [TSA for bearing defects, 2024](https://article.innovationforever.com/JMIM/20240004.html)).
- **Angular resampling / order tracking** (fractional samples-per-rev) (k).
- **Envelope (high-frequency resonance) analysis** at characteristic fault
  orders — the informed baseline in this crate (k).
- **Closed-loop predictive coding** (DPCM with the predictor updated from
  reconstructed samples) and **Rice/Golomb residual coding** — FLAC-era
  engineering (k).

## Adjacent — close neighbours, none the same object

- **Compression-rate-as-anomaly-signal**: established in general time-series
  work — normalized compression distance (Li/Vitányi, Keogh's CDM) (k),
  grammar-compression anomaly discovery
  ([Senin et al.](https://csdl.ics.hawaii.edu/techreports/2014/14-05/14-05.pdf)),
  compression-based anomaly frameworks
  ([arXiv 1908.00417](https://arxiv.org/abs/1908.00417)), and at least one
  patent stating low compression rate ⇒ abnormal operating state
  ([US 11,768,749](https://image-ppubs.uspto.gov/dirsearch-public/print/downloadPdf/11768749)).
  These use general-purpose compressors offline; none is a shaft-synchronous
  streaming format.
- **Vibration compression for wireless condition monitoring**: exists as
  schemes and case studies — DCT divide-and-compress lossless
  ([MDPI case study, 2025](https://www.mdpi.com/2076-3417/15/22/12346)),
  real-time compression in acquisition hardware
  ([ScienceDirect](https://www.sciencedirect.com/science/article/abs/pii/S0263224113002765)),
  generic time-series-database compression
  ([TDengine](https://tdengine.com/managing-high-frequency-vibration-data/)).
  None folds at the machine's own period; none treats its rate as the alarm.

## Not found (the scoped novelty conjecture)

No shipped **storage/stream format** was found that combines:
(a) segmentation at *fractional* shaft periods from vibration-refined speed,
(b) a closed-loop cycle-pool (TSA) predictor mirrored by the decoder with no
side stream, (c) a hard bounded-error wireless mode, and (d) per-revolution
byte accounting *as the shipped health metric*.

Status: **grounded-conjecture** — two scans, adjacent art abundant, absence
of evidence only. A patent-grade search was NOT done. The right next probe:
MIMOSA/OSA-CBM records, PI/OSIsoft swinging-door variants, and commercial CM
vendors' wire formats (Emerson AMS, SKF @ptitude, Bently Nevada).
