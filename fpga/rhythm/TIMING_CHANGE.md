# Pressure velocity pipeline candidate

Hardware: Tang Mega 138K, SOM 30354 / Dock 31005, V5 keyboard;
GW5AST-LV138PG484AC1/I0 (GW5AST-138C), Gowin 1.9.12.03.

Baseline: `v5_rhythm_20261107`, routed and bitstream generated, not programmed.
Setup 0.000 ns, hold +0.193 ns. The worst sys_clk path runs from ADC
`channels_103_s0` to `forces_sys_73_s0`, 14 logic levels, 19.915 ns data delay.
The deployed pre-rhythm baseline remains `v5_timing2_20261106` unchanged.

Changed: only `rtl/v3_analog_input.v` production logic. Divide the pressure
subtract / gain multiply / saturation / curve scaling / final force into
registered stages. Gate hysteresis and calibration are unchanged. Capture
keys plus XY metadata on the original publication edge, then submit them
with matching velocities four sys clocks later (80 ns at 50 MHz).
Snapshot the calibration mask before the acceptance edge updates calibration.

Held: clocks, resets, CDC modules, pin constraints, audio framing, thresholds,
curve arithmetic, key order, voice counts, rhythm protocol, place3/route2.
Regenerate the existing proof-based half-rate constraints from the fresh
netlist; no new timing exception for the new sys_clk registers.

Hypothesis: the ADC-to-force combinational cluster is removed by real pipeline
boundaries. Improved global slack is decided only by routed STA. If another
path becomes limiting, report its actual endpoints rather than randomly
changing implementation settings.

Verification: frozen baseline `sim/rhythm_baseline_analog.v` differs only in
module name. `tb_pressure_pipeline_exact` compares the entire CDC input word
and publication edge, exhausts delta 0..1023 and gain 128..255, crosses
calibration completion, unequal zero points, hysteresis boundaries, and reset
at every stage. Original SPI, audio timeout, per-key force, production latency
and rhythm pin tests remain in the full suite: 158 original plus 1 new = 159.

No hardware programming or GitHub push is part of this task.
