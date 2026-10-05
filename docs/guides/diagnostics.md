# Run diagnostics

When a CI run dies, you want to know three things: which phase it was in,
which mutants were running, and how big the processes were. Two flags
answer that. Both are off by default and cost nothing when off.

| Flag | Config key | What you get |
|---|---|---|
| `--diagnostics` | `diagnostics: true` | one human-readable line per event on stderr |
| `--events FILE` | `events_file: FILE` | the same events as NDJSON, one JSON object per line |
| `--sample-interval S` | `sample_interval: S` | seconds between memory samples (default 5) |
| `--max-rss SIZE` | `max_rss: SIZE` | stop the run when the gem's total memory reaches SIZE (`6G`, `6144M`, or plain MB) |

Both write to stderr or a file, never stdout, so `--format json` output
stays parseable. The `--events` file is written line by line as the run
goes, so a run killed with SIGKILL still leaves every event up to the kill.
A relative `FILE` is relative to the project root.

## Reading `--diagnostics` output

```
[active_mutator 14:02:11 +3.4s] phase baseline start refresh=full pid=4807
[active_mutator 14:03:40 +92.1s] mem parent=226M baseline=2.1G total=2.3G avail=3.0G swap=0 psi=0.3 load=1.52
[active_mutator 14:08:59 +411.2s] phase baseline end
[active_mutator 14:08:59 +411.3s] phase coverage_load start size=2.1G
[active_mutator 14:09:30 +442.0s] mutant start #12 pid=4242 parallel Foo#bar app/models/foo.rb:10 replace > with >=
[active_mutator 14:09:32 +443.8s] mutant end #12 killed 1.8s peak=812M
[active_mutator 14:09:40 +451.0s] abort sigterm; in flight: #13 Foo#baz app/models/foo.rb:40
```

Each line starts with the wall-clock time and the seconds since the run
started. If the log stops after a `phase ... start` with no matching
`end`, that phase is where the run died.

## Memory samples

With either flag on, a sampler thread records the gem's own memory every
`--sample-interval` seconds and at every phase boundary. It covers three
kinds of process: the parent, each live worker, and the baseline child.
Watching only one of them tells half the story. In the run that led to
this feature, the baseline child grew to 3.7 GB and exited, then the
parent grew to 6.6 GB reading its coverage file back.

| Platform | Per process | System fields |
|---|---|---|
| Linux | RSS and peak from `/proc/<pid>/status`, Pss from `/proc/<pid>/smaps_rollup` | `MemAvailable` and swap from `/proc/meminfo`, `some avg10` from `/proc/pressure/memory`, load from `/proc/loadavg` |
| macOS | RSS from one `ps` call per sample | none |
| other | none | none |

Workers are forks, so they share copy-on-write pages with the parent.
Adding up RSS counts those pages more than once. The total uses **Pss**
on Linux, which splits shared pages fairly between the processes that
share them. On macOS the total is an RSS sum, which runs high.

A worker can finish between two samples, so each worker also reports its
own peak (`VmHWM`) in its `mutant_end` event.

In the text line, `workers=4:3.2G` means four live workers using 3.2 GB
together, and `swap` is swap in use. A field the platform can't read
shows as `?` or is left out.

## A memory ceiling

`--max-rss 6G` watches the same memory samples and acts on their total
(Pss on Linux, RSS elsewhere). At 90% it prints one warning. At 100% it
stops the run the same way a signal does (below) and exits 3, so CI can
tell "ran out of memory" apart from "tests too weak". Both lines go to
stderr even without `--diagnostics`:

```
[active_mutator 14:09:10 +423.0s] warn memory at 91% of --max-rss 6.0G (5.5G)
[active_mutator 14:09:15 +428.1s] memory at 101% of --max-rss 6.0G (6.1G); stopping the run
```

On macOS the total is an RSS sum, which counts shared pages more than
once, so the ceiling trips early there. That's the safe direction.

Reading coverage.json back gets a check of its own, before the read.
Ruby's JSON parser holds the interpreter's global lock, so while it runs,
no memory sample is taken and no signal is handled. The ceiling instead
estimates the cost up front: the last sample plus about 5 times the
file's size, which is what parsing it took in testing. The line says so:

```
[active_mutator 14:09:15 +428.1s] memory at 150% of --max-rss 6.0G (9.0G estimated to read a 1.7G coverage.json); stopping the run
```

## Aborted runs

On SIGINT, SIGTERM, or a `--max-rss` breach, in any phase, the run kills its baseline child or
every running worker (each with its whole process group) without waiting
for them, emits an `abort` event naming the mutants still running, and
exits. CI runners give only a few seconds between SIGTERM and SIGKILL, so
nothing on this path waits. The reporter still prints its summary for the
mutants that finished, marked as partial: a `Partial mutation score:`
line in the terminal, and `"complete": false` in `--format json`. A
signal or breach that lands once the report has started doesn't cut it
short: the report finishes, no second one is printed, and the run still
exits with the code below.

| Reason | Exit |
|---|---|
| SIGINT | 130 |
| SIGTERM | 143 |
| `--max-rss` reached | 3 |

An aborted run never passes, whatever `--fail-at` says. SIGKILL (an OOM
kill, a VM teardown) can't be caught. For those, the lines already written
are what survives.

## Phases

| Phase | What runs |
|---|---|
| `boot` | loading operators, the app, and the spec helper in the parent |
| `planning` | finding subjects and generating mutants |
| `baseline` | the child `rspec` process recording coverage (`refresh` is `full` or `partial`; `pid` is the child's) |
| `coverage_load` | the parent reading the coverage file back (`bytes` before the read, `examples` after) |
| `mutating` | the fork pool running mutants (`mutants` is the planned count) |
| `escalating` | phase-2 reruns of class-body survivors against more spec files |
| `reporting` | the reporter's summary, and `--accept-survivors` |

A cached run has no `baseline` phase, only `coverage_load`. A partial
refresh reads the old cache, runs a `partial` baseline, reads its output
in a second `coverage_load`, and writes the merged file without reading
it back.

## The `--events` schema (v1)

Every line has these fields:

| Field | Type | Meaning |
|---|---|---|
| `v` | integer | schema version, `1` |
| `event` | string | event name, below |
| `t` | string | UTC wall time, ISO 8601 with milliseconds (`2026-09-23T14:02:11.123Z`) |
| `elapsed` | number | seconds since the run started (monotonic clock), 3 decimals |

New fields may be added under `v: 1`. Renaming or removing a field bumps
`v`.

### `phase_start`, `phase_end`

`phase` names the phase (see the table above). Some phases add fields:
`refresh` and `pid` on `baseline` start, `bytes` on `coverage_load` start,
`examples` on `coverage_load` end, and `mutants` on `mutating` and
`escalating` start.

### `mutant_start`

| Field | Meaning |
|---|---|
| `seq` | mutant number, unique across the run (escalation continues the count) |
| `pid` | the worker's process id |
| `lane` | `parallel` or `serial` |
| `budget` | timeout budget in seconds |
| `examples` | how many examples the mutant runs against |
| `subject`, `file`, `line`, `description` | which mutant it is |

### `mutant_end`

| Field | Meaning |
|---|---|
| `seq`, `pid` | match the `mutant_start` |
| `status` | `killed`, `survived`, `timeout`, `error`, or `skipped` |
| `seconds` | worker wall time |
| `peak_rss_kb` | the worker's own peak memory (`VmHWM`); `null` off Linux and for timeouts |

### `memory`

| Field | Meaning |
|---|---|
| `parent` | `{rss_kb, pss_kb}` for the parent, or `null` if unreadable |
| `workers` | `[{pid, seq, rss_kb, pss_kb}]`, one per live worker |
| `baseline` | `{pid, rss_kb, pss_kb}` for the baseline child, or `null` when none runs |
| `total_pss_kb` | the sum over all of the above: Pss where known, else RSS; `null` if nothing could be read |
| `system` | Linux only, else `null`: `{mem_available_kb, swap_total_kb, swap_free_kb, psi_some_avg10, load1}`, each `null` when its file is missing |

`pss_kb` is `null` off Linux, and on kernels without `smaps_rollup`.

### `abort`

| Field | Meaning |
|---|---|
| `reason` | `sigint`, `sigterm`, or `memory_ceiling` |
| `in_flight` | `[{seq, pid, subject, file, line, description}]`, the mutants killed mid-run; empty outside the `mutating` and `escalating` phases |
| `planned` | how many mutants the run planned, or `null` if it stopped before planning finished |
| `counts` | finished mutants by status, the same keys as the reporter's counts |
| `score` | the score over finished mutants only (0 to 1), or `null` if none finished |

The phase that was running gets no `phase_end`.

### `memory_warning`, `memory_ceiling`

`--max-rss` only. `memory_warning` comes once, when a sample's total first
reaches 90% of the ceiling. `memory_ceiling` comes when it reaches 100%,
right before the `abort`.

| Field | Meaning |
|---|---|
| `total_pss_kb` | the total that crossed the line |
| `max_rss_kb` | the ceiling |
| `coverage_bytes` | only on the check before coverage.json is read: the file's size, and `total_pss_kb` is then an estimate |
