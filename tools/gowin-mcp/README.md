# Gowin MCP 0.5.0

Dependency-free MCP bridge for Gowin EDA V1.9.12.03. It provides a bounded
AI development loop for project inspection, synthesis/place-and-route,
structured timing analysis, pin auditing, evidence-backed pin planning, CST
updates, and report reading.

It deliberately excludes Programmer operations, cable/device scans, SRAM or
Flash programming, erase, OTP, keys, security settings, arbitrary Tcl, and
arbitrary shell execution.

Tool result JSON is escaped to ASCII on the stdio boundary. This avoids a
Windows MCP proxy stall when board-profile evidence contains non-ASCII paths;
parsing the embedded JSON text restores the original Unicode strings.

## Tools

| Tool | Effect |
|---|---|
| `gowin_environment` | Check the configured IDE and CLI paths without touching hardware |
| `gowin_inspect_project` | Parse the `.gprj`, part number, enabled files, constraints, and missing paths |
| `gowin_build_project` | Run fixed `syn`, `pnr`, or `all` through `gw_sh`; optional `place_option`/`route_option` |
| `gowin_start_build` | Start a persistent worker and return a build ID immediately; same optional options |
| `gowin_build_status` | Read saved status, heartbeat, elapsed time, live log, and artifacts |
| `gowin_diagnose_log` | Group exact vendor errors/warnings and show the first error and last progress marker |
| `gowin_read_report` | Read a bounded report inside the selected project |
| `gowin_timing_summary` | Parse clocks, Fmax, Setup/Hold, TNS, worst paths, SDC coverage, and report freshness |
| `gowin_pin_audit` | Compare CST assignments with the newest final Pin Report |
| `gowin_plan_pins` | Allocate explicit top-level ports from a board profile without writing files |
| `gowin_apply_pin_plan` | Preview or atomically apply the same approved plan with a CST backup |

The user-level Codex and Claude MCP registries start this server. CCSwitch also
stores it as `gowin`, enabled for both clients. Restart a client after changing
the server or its configuration so its tool list is refreshed.

## Timing Loop

1. Run `gowin_start_build` with `stage="all"`, then poll `gowin_build_status` with its ID.
2. Run `gowin_timing_summary` against the same `.gprj`.
3. Inspect negative Setup/Hold slack, endpoint violations, TNS, Fmax margins,
   worst paths, and `clocks_without_explicit_sdc`.
4. Change HDL or SDC through the normal project filesystem, rebuild, and
   compare fresh evidence.

`timing_constraints_met=true` only means the analyzed constraints passed.
`timing_clean=true` additionally requires a fresh report and explicit SDC
coverage for every clock reported by Gowin. A coverage warning is not proof
that every path on that clock is unconstrained, but it blocks a timing-clean
claim until reviewed.

The MCP reads report files produced by Gowin. It does not attach to the live
GUI process or read unsaved GUI state.

## Long builds and recovery

Build metadata lives at `<project>/.gowin-mcp/<build_id>/`: fixed `build.tcl`,
merged `build.log`, worker diagnostics, and an atomically updated `receipt.json`.
A separate Python worker keeps the build alive when the MCP client disconnects.
The receipt records project, stage, tracked input hashes, tool/worker PIDs,
start/end times, heartbeat and final bitstream hashes. Reopen status using the
same project and ID after restarting the client.

`budget_seconds` warns only. A 30-second-old heartbeat changes a pending status
to `unknown`; it does not prove the tool died. A live heartbeat likewise does
not prove the routing algorithm made progress. Logs expose their own age and
last literal vendor progress line, not an invented completion estimate.

An exclusive project-directory lock blocks concurrent managed builds, including
from another MCP process. Direct CLI/GUI builds are outside this lock: check
those yourself before starting another build. No automatic cancel, restart,
stale-lock deletion or orphan killing is provided. If the worker was forcibly
terminated, inspect its recorded tool PID and preserve the logs before manually
recovering the lock. Never remove a lock while its build is still running.

The compatibility `gowin_build_project` accepts its previous arguments but now
returns the structured job status. `timeout_seconds` only bounds waiting;
`wait_timed_out=true` carries the still-owned ID for later polling. This is a
0.3 return-schema change: use `log`, `receipt_path`, `elapsed_seconds` and
`new_artifacts` instead of the former captured `stdout`/`stderr` fields.

`success=true` requires normal tool exit, no logged error, fresh stage artifact,
and unchanged tracked source inputs. It is **not timing acceptance**. Synthesis
requires a fresh nonempty synthesis report; implementation requires fresh
nonempty `.pr`, `*_tr_content.html`, `.pin.html` and `.fs` outputs. A placement
`.p`, a `.tr.html` wrapper, or a zero-unrouted log line cannot substitute for
these outputs. `stage_outputs` lists the evidence by role; `missing_outputs`
identifies absent roles. Nonzero reported unrouted counts also reject success.
Final status is invalidated if tracked source contents later change. The hash
scope is enabled project files plus in-project `.vh/.svh/.mem/.hex/.mi/.ipc/.sdc/.cst`
files outside generated directories; implicitly referenced external headers or
other data files still require explicit project-level provenance checks.

Report and bitstream hashes are also rechecked on completed status queries;
overwriting a build output invalidates the old receipt even when source files
have not changed.

## Place/route options and per-build report archive (0.4)

`gowin_start_build` and `gowin_build_project` accept two optional integers,
`place_option` (0-4) and `route_option` (0-2). They are the only build settings
a client can pass: each becomes one `set_option` line in the fixed `build.tcl`
before `run`; no Tcl text is accepted. They are rejected for `stage="syn"`.
Omitted options leave the project's own setting untouched.

After P&R the worker reads the tool's own `impl/pnr/cmd.do` and records
`applied_options`. A requested value that the tool did not record makes
`options_applied=false` and the build unsuccessful, so a receipt never claims a
profile that did not run.

Every finished build, failed or not, copies its fresh reports and logs to
`<project>/.gowin-mcp/<build_id>/reports/` with their `impl/...` relative paths
(`report_archive` in the receipt). Binary `.p`, `.pr` and `.fs` files are not copied; they are
identified by hash. The next build overwrites `impl/`, which still marks the
older receipt `stale-build`, but its timing, resource and pin reports remain
readable from the archive through `gowin_read_report`. This closes the gap
where a routed run's timing report was lost to a later run in the same
directory. `gowin_timing_summary` still parses the live `impl/` only.

## Evidence checks added in 0.5

`gowin_diagnose_log` adds `last_stage` (name, line and literal text),
`unrouted_nets` and `unrouted_evidence`. Stage names describe the last explicit
vendor marker, not live process state, ETA or completion. Report-generation
lines do not masquerade as a new routing stage. No count means `null`, not zero.
PR0004 remains an error even when its count is zero; final output and tool exit
still matter. Existing first-error and exact message counts are unchanged.

The authoritative artifact inventory no longer drops files after the first
100 entries. Placement and route binaries are included and hashed but not
copied into report archives. Status rechecks these hashes along with reports
and bitstreams; large route files therefore add read I/O to final status calls.

`gowin_timing_summary` preserves missing violation counters as `null` and reports
`missing_timing_data`. Missing setup/hold counters or slacks, missing/nonpositive
analyzed-path/endpoint counts, or invalid clock periods prevent a timing pass.
Otherwise nonviolating partial clocked reports get `status="incomplete"`;
stale data and observed violations still take precedence. A report's presence
alone remains insufficient for timing acceptance.

Restart the MCP client/server to load 0.5; no registration changes are needed.
Tests use fake processes and reports; historical-report replay is read-only.
Neither proves a new FPGA implementation or board behavior.

## Timing summary additions (0.4)

`gowin_timing_summary` also returns:

- `setup_clusters`: the setup paths Gowin printed, grouped by start and end
  register bank, with path count, worst slack, deepest logic level and mean
  routing share. It covers only the printed paths; `setup_paths_reported`
  says how many that was (25 unless the SDC raises it).
- `high_fanout_nets` and `route_congestion`: Gowin's own tables, present only
  when the SDC contains the SUG940 5.5 report constraints, for example
  `report_high_fanout_nets -max_nets 50 -min_fanout 30` and
  `report_route_congestion -max_grids 50`. To see more than 25 paths add
  `report_timing -setup -max_paths 200 -max_common_paths 1`.

These report constraints were accepted by V1.9.12.03 on the `live_smoke`
fixture on 2026-10-10 and parsed correctly. Their effect, if any, on the
placement of a large design has not been measured.
`gowin_diagnose_log` also works on existing CLI logs, without owning the process.
It keeps raw line numbers, exact total counts and the first error even if the
displayed message list is truncated. It does not treat log silence as a hang or
source-level suspicions as vendor diagnostics.

Design rationale and pinned upstream review: [review](../docs/RTL技能与MCP优化审阅_20261005.md).

## Pin Planning

Automatic pin placement is only safe when a board profile records the exact
board revision, exact project part number, evidence sources, and permitted
package pins. On-board clocks, DDR, SerDes, configuration, and fixed peripherals
must come from the schematic or an authoritative pin table. The placer is not
allowed to guess external wiring.

Board profile example:

```json
{
  "schema_version": 1,
  "board": "Example Board",
  "revision": "1.0",
  "device_name": "GW5AST-138C",
  "part_number": "GW5AST-LV138PG484AC1/I0",
  "evidence": ["docs/example-board-rev1-schematic.pdf"],
  "default_attributes": {
    "IO_TYPE": "LVCMOS33",
    "BANK_VCCIO": "3.3"
  },
  "pins": [
    {
      "pin": "V22",
      "signal": "clk_50m",
      "roles": ["clock"],
      "bank": "4",
      "priority": 0
    },
    {
      "pin": "A1",
      "signal": "header_gpio_1",
      "roles": ["gpio"],
      "bank": "1",
      "priority": 10,
      "attributes": {"PULL_MODE": "NONE"}
    },
    {
      "pin": "B1",
      "signal": "configuration_pin",
      "roles": ["gpio"],
      "reserved": true
    }
  ]
}
```

Planning requests name every HDL port explicitly:

```json
[
  {"port": "clk", "signal": "clk_50m", "role": "clock"},
  {
    "port": "led[0]",
    "role": "gpio",
    "attributes": {"DRIVE": "8", "PULL_MODE": "NONE"}
  }
]
```

Call `gowin_plan_pins` first and review its assignments, evidence, revision,
and `plan_id`. Then call `gowin_apply_pin_plan` with the same profile, requests,
and `expected_plan_id`. Its default `apply=false` returns a unified diff only.
Set `apply=true` to write; the server recomputes the plan, refuses stale IDs,
creates `*.cst.bak-<timestamp>`, and atomically replaces the CST. Run
`gowin_pin_audit`, build, and audit again to confirm final placement.

Profiles with revision `unknown`, `tbd`, or `?`, or without the exact project
`device_name`, are never apply-ready. The server also blocks device/part-number
mismatches, reserved pins, duplicate ports or package pins, unsupported IO
attributes, unresolved Bank voltage or IO type, and CST files outside the
selected project.

The verified local profile for Tang Mega 138K SOM 30354 + Dock 31005 with a
`GW5AST-138C` is under `profiles/`. It intentionally contains only the
evidence-backed low-speed on-board clock/reset, keys, LEDs, addressable LEDs,
audio, and UART resources. DDR3, HDMI, SerDes, camera, Ethernet, and other
interface buses require their matching IP and project-specific constraints.

## Paths And Registration

Gowin `gw_sh` V1.9.12.03 cannot reliably open non-ASCII project paths. Keep
buildable projects under an ASCII path such as `E:\Gowin\workspace`. The MCP
server itself may remain under `C:\Users\hck\Desktop\高云`.

The project-local `.codex/config.toml` mirrors the registered workspace
definition. Verify registration in the real user context; the offline Codex
sandbox account has a separate `CODEX_HOME`.

Run unit tests with:

```powershell
$env:PYTHONDONTWRITEBYTECODE = '1'
python -m unittest discover -s .\gowin-mcp\tests -v
```

## Verified Integration

On 2026-10-10, 0.4.0 passed 28 unit/protocol tests. Called in-process (not over
stdio), `gowin_build_project(stage="all", place_option=3, route_option=2)` built
the `live_smoke` fixture with real Gowin V1.9.12.03 in 19.761 seconds: the
generated `build.tcl` carried both `set_option` lines, `cmd.do` confirmed 3/2,
and 13 report files were archived under the build ID. Never programmed. The
full instrument design has not yet been built through this path.

On 2026-10-05, 0.3.0 passed 24 unit/protocol tests. Its nonblocking stdio start
then ran the isolated `tests/fixtures/live_smoke` project with real Gowin
V1.9.12.03; the client exited while the worker continued. Another client read
the completed receipt after 22.838 seconds, with matching input/artifact hashes,
zero tool errors, fresh bitstream, clean timing and matching three-pin report.
This was a build-bridge smoke test, never programmed. Full evidence is retained
under `artifacts/rtl_skill_mcp_20261005` in the workspace.

On 2026-09-21, version 0.2.1 ran a fresh ASCII-path extraction of the local
`key_ctrl_led` course project through the stdio MCP and the official local
node-locked license. `gowin_build_project(stage="all")` completed in 31.483
seconds and generated a fresh 34,690,863-byte `.fs`, with no license error.

The same run parsed the full `_tr_content.html` report rather than Gowin's
small `.tr.html` wrapper. It found three clocks, zero Setup/Hold violations,
0 ns TNS, 3.210 ns worst Setup slack, and 0.224 ns worst Hold slack. Only
`clk` had an explicit SDC clock; the two fabric-derived clocks remain coverage
gaps, so the result is `met-with-coverage-gaps`, not timing-clean. The fresh
Pin Report matched all 14 CST locations and had no automatic assignments.

That proves the IDE build bridge, report parsing, pin audit, and bitstream
generation. It does not prove programming or board behavior.
