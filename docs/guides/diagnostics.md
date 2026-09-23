# Run diagnostics

When a CI run dies, you want to know three things: which phase it was in,
which mutants were running, and how big the processes were. Two flags
answer that. Both are off by default and cost nothing when off.

| Flag | Config key | What you get |
|---|---|---|
| `--diagnostics` | `diagnostics: true` | one human-readable line per event on stderr |
| `--events FILE` | `events_file: FILE` | the same events as NDJSON, one JSON object per line |

Both write to stderr or a file, never stdout, so `--format json` output
stays parseable. The `--events` file is written line by line as the run
goes, so a run killed with SIGKILL still leaves every event up to the kill.
A relative `FILE` is relative to the project root.

## Reading `--diagnostics` output

```
[active_mutator 14:02:11 +3.4s] phase baseline start refresh=full
[active_mutator 14:08:59 +411.2s] phase baseline end
[active_mutator 14:08:59 +411.3s] phase coverage_load start size=2.1G
[active_mutator 14:09:30 +442.0s] mutant start #12 pid=4242 parallel Foo#bar app/models/foo.rb:10 replace > with >=
[active_mutator 14:09:32 +443.8s] mutant end #12 killed 1.8s peak=812M
```

Each line starts with the wall-clock time and the seconds since the run
started. If the log stops after a `phase ... start` with no matching
`end`, that phase is where the run died.

## Phases

| Phase | What runs |
|---|---|
| `boot` | loading operators, the app, and the spec helper in the parent |
| `planning` | finding subjects and generating mutants |
| `baseline` | the child `rspec` process recording coverage (`refresh` is `full` or `partial`) |
| `coverage_load` | the parent reading the coverage file back (`bytes` before the read, `examples` after) |
| `mutating` | the fork pool running mutants (`mutants` is the planned count) |
| `escalating` | phase-2 reruns of class-body survivors against more spec files |
| `reporting` | the reporter's summary, and `--accept-survivors` |

A cached run has no `baseline` phase, only `coverage_load`. A partial
refresh reads the old cache, runs a `partial` baseline, and writes the
merged file without reading it back.

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
`refresh` on `baseline` start, `bytes` on `coverage_load` start,
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
