# Gowin Tcl And MCP

## Verified Local Tools

Preferred installation:

```text
E:\Gowin\Gowin_V1.9.12.03_x64
```

- Tcl shell: `IDE\bin\gw_sh.exe`
- GUI: `IDE\bin\gw_ide.exe`
- Programmer CLI: `Programmer\bin\programmer_cli.exe`

`gw_sh.exe` was started successfully. `programmer_cli.exe --help` reports
V1.9.12.03 (64-bit), build 2712. Help output is interface evidence only; no
cable or FPGA was scanned.

## Supported Tcl Build Path

The installed SUG1220-2.0 manual documents both interactive mode and:

```powershell
& 'E:\Gowin\Gowin_V1.9.12.03_x64\IDE\bin\gw_sh.exe' 'C:\path\build.tcl'
```

Minimal script:

```tcl
open_project {E:/path/project.gprj}
run all
run close
```

Useful documented commands include `create_project`, `open_project`,
`add_file`, `set_device`, `set_option`, `run syn`, `run pnr`, `run all`,
`saveto`, and `run close`. Do not expose arbitrary Tcl through MCP: project
builds need only the fixed `open_project`/`run`/`close` sequence.

## Local MCP

The server is at:

```text
C:\Users\hck\Desktop\高云\gowin-mcp\server.py
```

The trusted project configuration is:

```text
C:\Users\hck\Desktop\高云\.codex\config.toml
```

It registers a stdio server named `gowin`, constrained by
`GOWIN_ALLOWED_ROOTS`. Restart Codex in this workspace after configuration
changes to expose tools.

| MCP tool | Effect |
|---|---|
| `gowin_environment` | Read-only executable/path check |
| `gowin_inspect_project` | Read and validate one `.gprj` |
| `gowin_build_project` | Run fixed `syn`, `pnr`, or `all`; writes ordinary build output |
| `gowin_start_build` | Start persistent fixed build, return `build_id` immediately |
| `gowin_build_status` | Read receipt, heartbeat, live log and final artifacts by ID |
| `gowin_diagnose_log` | Read current or historical CLI log with exact counts and bounded messages |
| `gowin_read_report` | Read a bounded text report inside that project |
| `gowin_timing_summary` | Parse fresh STA clocks, Setup/Hold, TNS, Fmax, worst paths, and SDC coverage |
| `gowin_pin_audit` | Compare CST assignments with the final Pin Report |
| `gowin_plan_pins` | Produce an evidence-backed board pin plan without writing |
| `gowin_apply_pin_plan` | Preview or atomically apply an unchanged plan with a CST backup |

The server has no arbitrary shell/Tcl tool and no device scan, erase, program,
Flash, OTP, key, or security operation.

Since 0.4 both build tools take optional `place_option` (0-4) and
`route_option` (0-2), the only build settings a client can pass. Use the pair
that last routed this design instead of dropping to a hand-written Tcl script:
the worker checks them against the tool's `impl/pnr/cmd.do` (`applied_options`,
`options_applied`) and copies each run's fresh reports to
`<project>/.gowin-mcp/<build_id>/reports/`. Read an earlier run's timing or
resource report from that archive; `impl/` only holds the latest run. If the
connected client still shows the 0.3 schema, restart it before relying on
these arguments.

For long builds prefer `gowin_start_build(project_file, stage, budget_seconds)`
then `gowin_build_status(project_file, build_id)`. Receipts and logs are under
`<project>/.gowin-mcp/<build_id>/`. A separate worker survives MCP disconnects;
poll the same ID after reconnecting. Heartbeat older than 30 seconds makes a
pending state unknown; investigate the worker/tool PIDs rather than restarting.
A responsive worker is not proof that the EDA algorithm advances.

`budget_seconds` is advisory. Since 0.3, `gowin_build_project` retains its call
arguments but returns the same structured status as the asynchronous interface;
`timeout_seconds` limits waiting, not EDA lifetime. On `wait_timed_out`, keep the
ID and poll later. Consumers should use `log`, `receipt_path`, `elapsed_seconds`,
and `new_artifacts`; the old captured `stdout`/`stderr` fields are replaced by
the durable merged log. No timeout or quiet log triggers automatic termination.

Build success proves fresh stage output and unchanged tracked input hashes,
not acceptable timing. Run the existing timing and pin audits afterward. The
input fingerprint covers enabled files plus project-local header, memory,
constraint and IP configuration files; external implicit includes require
separate accounting. One lock protects managed builds per project directory;
external GUI/direct-CLI builds are not adopted or blocked automatically.

Gowin `gw_sh` V1.9.12.03 cannot reliably open non-ASCII project paths. Keep
buildable projects under an ASCII path such as `E:\Gowin\workspace`; the MCP
returns an early actionable error instead of passing a corrupted path to Gowin.

Pin writes use a two-phase contract: an exact device/revision board profile and
requests produce a content-bound `plan_id`; apply recomputes the plan, rejects a
stale ID, backs up the CST, and replaces it atomically. Rebuild plus a fresh pin
audit is still required before accepting the placement.

If MCP is not active in the current session, use the same fixed Tcl script via
`gw_sh.exe`, save stdout/stderr, and inspect fresh report/artifact timestamps.
