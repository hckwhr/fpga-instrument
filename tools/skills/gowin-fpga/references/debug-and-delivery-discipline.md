# Debug, Robustness And Delivery Discipline

> Source of the methods: the Anlogic "完赛系列" course and the national on-site
> Verilog test collection under `E:\安路代码参考`, re-read 2026-10-10.
> Only vendor-neutral method is kept. Every tool, constraint and report detail
> below is Gowin's own, checked against the installed V1.9.12.03 manuals or a
> real build on this machine; each such claim names its evidence.

## 1. What was not ported

Anlogic and Gowin differ in tools, primitives and constraint dialect. None of
the following may be copied from that course into a Gowin project:

- SDC text. SUG940-2.0.4 (Gowin timing constraints) has no `rename_clock` and
  no `-datapath_only`; the course SDC uses both, plus Anlogic object paths.
- TD download steps, EG4S20 Flash/boot settings, `EG_PHY_*` primitives, the
  encrypted SDRAM/HDMI cores, PLL wrapper port names and reset polarity.
- Numbers tied to that device: clock frequencies, `set_clock_uncertainty`
  values, LUT/BRAM budgets, timeout cycle counts.
- Its remedy "three PLLs into one". Clock architecture is decided from the
  Gowin board, UG306 and the generated PLL IP, not by analogy.

Programming always follows the active project's own verified procedure
(for the instrument project: `docs/固定烧录配置.md`).

## 2. One variable per experiment

Before a build or board run, write four lines:

- changed: the single thing that differs from the baseline;
- held: what is byte-identical (netlist inputs, constraints, options, board);
- if A: what result A rules out;
- if B: what result B rules out.

Evidence from the instrument project, 2026-10-09/10: a four-multiplexer RTL
change turned a 13-minute routed build into a 72-minute `PR0004` (104 unrouted);
a fanout attribute on one control net took setup violations from 22 to 750. In
both cases a second simultaneous change would have made the cause unknowable.
Near the routability limit, "small" is not evidence of "harmless".

Two runs of one design also differ by placement alone. A change that removed
its targeted path cluster still produced a worse worst slack (-0.092 ns to
-0.766 ns) because unrelated paths landed differently. Judge a timing change on
several placements of the same netlist (`place_option` variants in separate
directories; the router is single-threaded, so they run in parallel), not on
one run.

## 3. A diagnostic must prove its own isolation

"A bypass parameter is set" is not "the variable is isolated". Before trusting
a diagnostic or a bench that forces internal signals, show from ports and state
machines that:

- the original producer's requests are really blocked;
- the original responses are really ignored;
- counters count only real handshakes;
- the diagnostic source is in the file list the build actually used.

The instrument project met this from the other side: seven top-level benches
`force` mode wires and so bypass the control module; when a decode moved inside
that module they failed although the RTL was equivalent. A bench that forces a
wire tests everything except the logic that drives that wire; record which
module-level bench covers the bypassed logic.

## 4. Evidence ladder

Extends the levels in `development-workflow.md` past `observed`:

| Level | Shows | Does not show |
|---|---|---|
| simulation pass | RTL is self-consistent under the model | silicon timing, vendor IP behaviour |
| status/UART/LED | the control state machine runs | that output data is right |
| one observation | this frame / this note is right | transitions, long runs |
| full cycle observed | every mode and transition works once | endurance, faults |
| soak + cold starts | deliverable stability | nothing further at bench level |

Report the level reached. For audio, a status flag saying a voice is active is
level 2; a decoded PCM capture is level 3.

## 5. Outside-in isolation

When output is wrong, start at the pin and add one responsibility per step;
the first step that fails holds the cause. For a Gowin audio/LCD design:

1. fixed pattern generated in the output domain (serializer / LCD timing only);
2. the same pattern through the output adapter and its contract;
3. a synthetic source through the mixer or compositor;
4. a synthetic source through each clock-domain crossing;
5. one real voice or one real layer;
6. full polyphony / full composition;
7. the complete product loop with user input.

## 6. Robustness rules

- Every wait on something outside the module has a timeout that is cleared on
  state entry; a parameter gives it in cycles from a clock-frequency parameter.
- A failure produces an error code and a pulse upward; the owner retries a
  bounded number of times, then skips, and keeps the last good output on screen
  or in the DAC path throughout.
- "Done" is decided by counting what was actually produced (samples, pixels,
  events), not by the upstream length field alone.
- Any walk over external or table-driven data has an iteration cap.
- Errors are sticky and visible (status page, LED, UART), cleared only by reset
  or an explicit command.
- New behaviour meets an old interface in an adapter; the proven driver is not
  edited.

## 7. Reset and start-up

Vendor-neutral requirements; realise them with the Gowin PLL IP's own lock
output and the project's reset synchronisers:

- asynchronous assert, synchronous release, one synchroniser per clock domain;
- every PLL lock is part of the reset source, not just one of them;
- start-up is ordered: locks, then memories/serializers ready, then sources
  enabled, then output un-muted; each step waits for a completion signal;
- a start-up error is reported, not run through.

Test it: repeated reset presses, and at least ten power cycles from Flash.

## 8. Gowin timing constraints and reports

Verified in SUG940-2.0.4E (Gowin Design Timing Constraints User Guide):
`create_clock`, `create_generated_clock`, `derive_clocks`, `set_clock_groups`,
`set_clock_latency`, `set_clock_uncertainty`, `set_false_path`,
`set_max_delay`/`set_min_delay`, `set_multicycle_path`, `set_input_delay`,
`set_output_delay`, `set_operating_conditions`; collections `get_ports`,
`get_pins`, `get_nets`, `get_regs`, `get_clocks`.

Rules:

- Each exception carries a comment naming the mechanism that makes it safe
  (synchroniser, request/acknowledge, reset release), as the instrument SDC
  already does. An exception without a stated mechanism is a defect.
- Prefer the narrowest object (`-through` a pin, `-to` a register) over a
  clock-to-clock exception.
- Do not answer a guardband-sized violation with hand-inserted delay cells or
  by loosening uncertainty copied from another vendor.

Report constraints (SUG940 5.5) change what the timing report prints, not what
is constrained. Confirmed on a real V1.9.12.03 build, 2026-10-10:

```sdc
report_timing -setup -max_paths 200 -max_common_paths 1
report_high_fanout_nets -max_nets 50 -min_fanout 30
report_route_congestion -max_grids 50
```

- `report_timing` defaults to 25 paths, so an unmodified report shows only the
  worst 25; raise it before concluding which clusters matter.
- The fanout table lists FANOUT, NET NAME, WORST SLACK, MAX DELAY per net.
- The congestion table lists GRID LOC and ROUTE CONGESTIONS per grid.

`gowin_timing_summary` returns them as `setup_clusters`,
`setup_paths_reported`, `high_fanout_nets` and `route_congestion`. Not yet
confirmed: that adding these lines leaves a large design's placement and
routing unchanged. Until it is, add them in a separate build, not on the
candidate being accepted.

## 9. Acceptance soak

Adapt the counts to the product, keep the categories:

- 30 minutes in the busiest automatic mode with no stuck state or artefact;
- 100 rapid key presses with none lost or doubled;
- 10 power cycles from Flash, all starting correctly;
- one hour warm, same checks.

## 10. Contest narrative

Vendor-neutral, for the design report and defence:

- Each feature answers: who uses it, what breaks without it, what the judge
  sees when it is triggered, and where its input comes from on this board.
- Keep one table: contest clause, why the scenario needs it, implementation,
  demo action. An empty cell is where report and product disagree.
- Script the demo by the second, starting with a power cycle.
- Claim only what the board produces. Anything that needs data the board does
  not have is described as supplied upstream, and said so.
- Depth on one or two extensions beats a list; state which ones were deepened.

## 11. National on-site Verilog test

Per the collector's own account in that folder (one person's report, not an
official rule): the national final includes an offline written-RTL test; the
problem arrives with a testbench, and acceptance is by waveform.

Past problems kept there: BCD adder, function generator, sequence generator,
signed accumulator / two's complement (2020); elevator, Mealy and Moore
sequence detectors (2023); digital clock and game counter (2024); serial
password lock with lockout, traffic light with pedestrian interrupt and
cooldown (2025). All are counters plus a small state machine with exact cycle
counts.

Practice rules:

- Write the cycle-exact contract first: which edge samples an input, how many
  clocks an output lasts, what happens on the last count.
- Off-by-one-cycle output is the recurring failure there; decide registered
  versus combinational outputs deliberately.
- The stored personal solutions are unverified. The 2025 traffic-light file
  visibly departs from the problem statement, so check any of them against the
  supplied testbench before using it as a model.
- The test is tool- and vendor-neutral; rehearse with the local ModelSim.
