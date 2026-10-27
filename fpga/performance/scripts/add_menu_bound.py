"""Add ONLY the 47 reviewed 54i menu-control endpoint exceptions."""
import hashlib
import json
import re
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
BASE=ROOT.parent/'v3_full_stage54i_20261017'
ARCHIVE=ROOT.parents[1]/'artifacts/v3_full_stage54j_20261017'
REPORT=ROOT.parents[1]/'artifacts/v3_full_stage54i_20261017/timing_classification.json'
SOURCE='u_instrument/u_instrument_control/test_polyphony_s0/Q'

def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()

def main():
    original=json.loads(REPORT.read_text(encoding='utf-8'))
    paths=[p for p in original['paths'] if p['source']==SOURCE]
    endpoints=[p['sink'] for p in paths]
    prefix='u_instrument/u_physical_string_bank/strings[1].voice/'
    assert len(paths)==len(set(endpoints))==47
    assert sum(bool(re.fullmatch(re.escape(prefix)+r'fill_phase_\d+_s0/CE',p)) for p in endpoints)==31
    assert sum(bool(re.fullmatch(re.escape(prefix)+r'loop_value_\d+_s0/CE',p)) for p in endpoints)==16
    locked=[]
    for folder in ('rtl','src'):
        for path in (ROOT/folder).rglob('*'):
            if path.is_file():
                rel=path.relative_to(ROOT)
                assert sha(path)==sha(BASE/rel),f'RTL changed: {rel}'
                locked.append(dict(path=str(rel),sha256=sha(path)))
    assert sha(ROOT/'constraints/v3_hardware.cst')==sha(BASE/'constraints/v3_hardware.cst')
    # Source facts below are reviewed in menu_bound_proof.md and verified by
    # tb_menu_delay_contract. The assertions detect later accidental drift;
    # string searches alone are NOT a proof of sequential safety.
    ctrl=(ROOT/'rtl/instrument_control.v').read_text(encoding='utf-8-sig')
    assert 'if (setting_mode && !setting_press_pulse)' in ctrl
    assert "self_test_active <= test_mode_n && !setting_mode_n;" in ctrl
    assert "test_polyphony <= (edit_field == FIELD_POLYPHONY);" in ctrl
    assert ctrl.count('test_polyphony   <=')==1  # reset, apart from the menu assignment
    base=(BASE/'constraints/v3_hardware.sdc').read_text(encoding='utf-8-sig')
    lines=[base.rstrip(),'',
        '# 54j: ONLY test_polyphony -> 47 reviewed string[1] endpoints.',
        '# Same audio_clk, NOT an asynchronous CDC or an assumed slow input.',
        '# instrument_control.v:184,303: bit changes only with setting_mode=1',
        '# and setting_press_pulse=0. At that edge setting_mode remains 1;',
        '# lines 349-351 keep audition_active and self_test_active at zero.',
        '# av_top.v:259,779: concurrent_active is masked by self_test_active;',
        '# ordinary string enable is masked by play_mute=setting_mode|test_mode.',
        '# Consequently the receiver bank is disabled throughout this edit.',
        '# Menu exit cannot share the edit edge. With common half CE the earliest',
        '# exit/self_test_active update is +2 audio clocks (40.690 ns); downstream',
        '# sequential state cannot use that update until the following edge.',
        '# 40.000 ns bounds this control propagation before enable can unmask it.',
        '# No debounce/human reaction time is assumed. Reset assertions remain',
        '# on their existing constraints; this exception begins at the Q pin only.',
        '# fill_phase/CE: ordinary enable qualifies FILL progression. During edit',
        '# enable=0 and state returns/remains IDLE; every new FILL resets fill_phase.',
        '# loop_value/CE: LOSS_SUM only executes while enabled; disable enters IDLE.',
        '# Existing loop data is not used while muted; restart follows FILL/READ.',
        '# Proof and exact endpoint inventory: artifacts/v3_full_stage54j_20261017.',
        '# tb_menu_delay_contract: 40 ns injection, earliest +2-clock exit, eight',
        '# strings; negative control removes menu mask and MUST detect divergence.',
        '# SUG940 5.4.2: set_max_delay affects setup/recovery ONLY. Existing hold',
        '# requirements remain in force: do NOT add false_path or set_min_delay.',
        '# All other sources, endpoints, clocks and existing MCP pairs unchanged.',
        f'set_max_delay -from [get_pins {{{SOURCE}}}] -to [get_pins {{']
    lines.extend('  '+p.replace('[','?').replace(']','?') for p in sorted(endpoints))
    lines.append('}] 40.000')
    sdc=ROOT/'constraints/v3_hardware.sdc'
    sdc.write_text('\n'.join(lines)+'\n',encoding='utf-8')
    ARCHIVE.mkdir(parents=True,exist_ok=True)
    result=dict(baseline_report_sha256=original['report_sha256'],source=SOURCE,
                paths=paths,max_delay_ns=40.0,rtl_unchanged=locked,
                original_sdc_sha256=sha(BASE/'constraints/v3_hardware.sdc'),
                sdc_sha256=sha(sdc),hold_unchanged=True,
                test_evidence_required=['tb_menu_delay_contract','menu_delay_negative'])
    (ARCHIVE/'menu_bound_inventory.json').write_text(json.dumps(result,indent=2),encoding='utf-8')
    print('Added one bounded exception, 47 exact endpoints; baseline SDC and RTL preserved.')

if __name__=='__main__':main()
