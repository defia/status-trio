# Memory lifecycle sampling and evidence (2026-10-20)

## Scope and result

`scripts/measure-memory-lifecycle.swift` is a read-only macOS sampler for a
single existing PID. It records monotonic timestamps, elapsed time, process
identity, physical footprint, RSS, lifetime peak footprint, and the number of
on-screen CoreGraphics windows owned by that process.

The tool is ready for a controlled product A/B run. This task did not launch,
stop, or modify a Status Trio app, and it did not reproduce the historical
342.1 MiB lifetime peak. The existing 30 MiB closed and 59 MiB open
observations remain historical evidence, not output from the new sampler.
There is no evidence for a leak or a Bluetooth attribution.

## Invocation

```bash
swift scripts/measure-memory-lifecycle.swift \
  --pid <pid> \
  --seconds 60 \
  --interval-ms 100 \
  --output /path/to/new-run.jsonl
```

The destination must not already exist. Publication uses
`renameatx_np` with `RENAME_EXCL`, so a concurrent creator can never be
overwritten. A failed or interrupted run removes its temporary file and never
publishes partial JSONL. This prevents an old or partial file, or another
process's output, from being mistaken for the requested run.

Each JSONL sample contains:

- `timestamp` and `elapsed`, both based on monotonic `systemUptime`;
- `pid`, `executablePath`, `executableUUID`, and `startAbstime`;
- `footprintBytes` / `footprintMiB`;
- `rssBytes` / `rssMiB`;
- `lifetimePeakFootprintBytes` / `lifetimePeakFootprintMiB`;
- `visibleWindowCount`;
- the sampler's separate `observer.pid` and `observer.executablePath`.

`visibleWindowCount` is the count of rows returned by
`CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements])`
whose owner PID matches the target. It does not identify a panel, read a
window title, or capture window content. A zero window count is not treated as
unknown; failure to obtain the CoreGraphics list is an error.

Memory and identity come from `proc_pid_rusage` with `RUSAGE_INFO_V4`, plus
`proc_pid_path`. Zero footprint, RSS, or lifetime peak is rejected. Every
sample is compared with the initial process identity, and a final identity
check runs after the scheduled samples. A kqueue `EVFILT_PROC` watcher for
`NOTE_EXEC | NOTE_EXIT` is registered before canonical identity is read, which
closes the identity-read/registration interval for same-path re-exec. After
the final identity check, the nonblocking process-event query is the immediate
operation before exclusive publication, while the monitor remains active.
That validation is the accepted measurement boundary: no post-publication
polling attempts to invalidate the completed measurement, and no output path
is removed after a successful rename. Target exit, PID reuse, or exec before
the boundary causes a nonzero exit with no retained output.

## Historical evidence, kept separate

On 2026-10-20, PID 30128 was manually observed in the development build
`dist-dev/Status Trio (Memory Optimization).app` from source baseline
`99d6fa998187ba2d5beced13377ed9ceee6ca263`.

| Manual state | Samples | Footprint median / peak (MiB) | RSS median / peak (MiB) | Lifetime peak (MiB) | Window observation |
|---|---:|---:|---:|---:|---|
| Closed as labeled | 60 | 30.0009 / 30.0477 | 128.375 / 128.422 | 65.45 | not captured for this interval |
| Open as labeled | 60 | 59.1962 / 59.2509 | 164.938 / 165.000 | 342.1 | 1 visible window in 60/60 samples |

Raw files:

- `/Users/lingsmbp/Documents/aiwork/status-trio-memory-measurements/2026-10-20/manual-dev-current-30128.json`
- `/Users/lingsmbp/Documents/aiwork/status-trio-memory-measurements/2026-10-20/manual-dev-panel-open-30128.json`
- `/Users/lingsmbp/Documents/aiwork/status-trio-memory-measurements/2026-10-20/manual-dev-panel-open-30128.windows.jsonl`

The window file establishes that a window owned by PID 30128 was on screen
during the labeled open interval. It does not prove which panel was visible.
The 29.2 MiB difference between the two medians and the 342.1 MiB cumulative
lifetime peak have different measurement scopes. The peak cannot be used as a
steady-state cost or assigned to the open panel.

The earlier fixed-closed three-run comparison is also historical input, not
new Task 5 output:

| Variant | Three-run footprint median of medians (MiB) | Highest sampled peak (MiB) | Highest lifetime peak among runs (MiB) |
|---|---:|---:|---:|
| Baseline | 14.6571 | 14.7977 | 18.6414 |
| Earlier optimized build | 14.8602 | 15.0633 | 18.8758 |

That result showed no steady-state reduction in the fixed-closed scenario.
Raw data is under
`/Users/lingsmbp/Documents/aiwork/status-trio-memory-measurements/2026-10-20/task7-confirm-20261020T0444/`.
A separate passive observer recorded no on-screen windows for those 82-83
sample target runs. These values must not be merged with the PID 30128 manual
open/closed pair.

## Final local development build

The final lifecycle changes were built as development version `1.6.0 (37)`
with Bundle ID `com.lingsmbp.StatusTrio.dev.memory-optimization`. The app and
privileged/mobile helper bundles passed their build-version, signature, and
bundle-integrity checks. The development bundle launched from:

`/Users/lingsmbp/.codex/worktrees/memory-optimization/status-trio/dist-dev/Status Trio (Memory Optimization).app`

It ran as PID 72135 with executable SHA-256
`00cb5c49a33d4adfeea3b3edf7e5476c4b9b8e8b41a83d1670468e0639527453`
and UUID `ed10eac7322c3052b235dcbf3046069c`. A passive 15-second capture while
the panel was closed and the app remained idle produced 31 samples:

| Metric | Median / peak |
|---|---:|
| Physical footprint | 22.954 MiB / 22.954 MiB |
| RSS | 95.047 MiB / 95.047 MiB |
| Lifetime peak footprint | 59.813 MiB |
| On-screen windows | 0 / 0 |

Raw JSONL:
`.superpowers/sdd/2026-10-20-memory-lifecycle-optimization/final-dev-72135-20261021-011059.jsonl`.

A later 30-second capture after more than two minutes of process uptime produced
31 samples with a 22.938 MiB median and 22.954 MiB peak footprint; RSS ranged
from 95.047 to 95.078 MiB, lifetime peak stayed at 59.813 MiB, and all samples
reported zero visible windows. Raw JSONL:
`.superpowers/sdd/2026-10-20-memory-lifecycle-optimization/final-dev-72135-stability-20261021-011305.jsonl`.

This run is development-build evidence, not a baseline/candidate A/B. It had
no panel, Settings, or Onboarding interaction and cannot establish long-running
stability, phase-specific reduction, or Bluetooth/AirPods attribution.

## Tool verification

The portable tests compile the Swift tool while holding the plan's
`swift.lock`, the same mutex used by `run-swift.py`, and target macOS 13
deployment. The test-first run failed because the implementation did not yet
exist. The completed suite covers:

- invalid and missing arguments;
- nonexistent, exited, and mid-run exiting PIDs;
- executable identity changes without PID reuse;
- same-binary re-exec detection with unchanged path/UUID/start identity;
- same-binary re-exec during the registration handshake;
- same-binary re-exec before the final identity/event boundary;
- post-boundary exec and atomic output-path replacement, proving there is no
  post-publication revalidation or cleanup that can delete the competitor;
- fresh-output enforcement, concurrent-creator exclusion, and no partial output
  on failure;
- stable nonzero memory/identity records and monotonic timestamps;
- absence of window-title or content fields;
- nonzero launch-marker publication failure through the GUI-free helper seam.

Command:

```bash
python3 -m unittest discover -s scripts/tests -v
```

Result: 17 tests ran; 15 portable tests passed, 2 opt-in desktop probes were
skipped. The skipped tests are intentional so default discovery neither creates
an AppKit window nor treats the desktop probe as a pass. The default marker seam
calls the same phase-helper implementation used by the GUI harness.

## Native window probe boundary

`scripts/tests/memory-lifecycle-window-harness.swift` is a test-only AppKit
helper. When explicitly enabled with
`STATUS_TRIO_ENABLE_WINDOW_HARNESS_TESTS=1`, it schedules
launch -> first expand -> close -> reopen and writes timestamped phase markers.
The sampler remains the independent observer. A privacy canary verifies that
the marker and JSONL path do not expose the helper window's title. A phase
marker write failure terminates the helper with a nonzero status; it cannot
silently yield incomplete phase evidence. The default suite verifies launch
marker publication failure through a GUI-free executable seam. The opt-in GUI
phase and unwritable-path probes were not run in the final residual validation,
so no native window-probe pass is claimed.

An earlier short helper-window probe confirmed that the CGWindow count changed
from one visible helper window to zero after hiding it and that the canary title
was absent. The six-second closed/reopen version did not produce a reliable
complete phase sequence across three attempts. The doubtful assumption was
that helper main-run-loop timers and an external sampler would stay aligned
without a controller. The workspace's Computer Use attempt also failed to
control the target window reliably.

The probe therefore stays opt-in and skipped by default. Its failure is not
counted as a pass, and it is not evidence about optimized Status Trio memory.
The parent's `StatusBarController` lifecycle test will provide the product
controller functional proof; a separately coordinated native menu-bar run is
still needed for full-app footprint and real WindowServer acceptance.

## Remaining measurement protocol

A valid product comparison should use the same source, feature settings,
display environment, and input/charging state for baseline and candidate.
Warm up by the same duration, sample at 100-1000 ms, and record at least three
fresh processes per variant. Each run must retain its process identity and
phase markers for launch, first expansion, at least six closed seconds, and
reopen.

The report should calculate each phase's sampled footprint peak separately
from `lifetimePeakFootprint`, preserve all raw JSONL, and inspect SwiftUI
hosting or image decode only when a reproducible phase or allocation trace
identifies a source. Until then, the 342.1 MiB event remains unreproduced and
does not justify a product patch.

The implementation and full local verification are complete. Acceptance still
requires the Xcode 26.6 / Swift 6.3.3 CI preflight and native tests on the target
macOS 13 runtime. A full product comparison also needs physical Bluetooth,
iPhone, and AirPods states, WindowServer/Spaces and multi-display coverage, and
manual panel, Settings, and Onboarding interaction.
