"""Read-only Verilog statement scanner used by the common-CE audit.

Keep the scanner and candidate module set from the original CE transformation,
without importing its historical source tree or running a source rewrite.
Membership only selects modules for inspection: audit_half_rate.py still proves
each process enable and each synthesized endpoint before emitting exceptions.
"""
import re


TOKEN = re.compile(r'//[^\n]*|/\*[\s\S]*?\*/|"(?:\\.|[^"\\])*"|[A-Za-z_$][\w$]*|\d+\'[^\s,;(){}]+|\d+|<=|==|!=|&&|\|\||[^\s]')


def tokens(text):
    return [(m.group(), m.start(), m.end()) for m in TOKEN.finditer(text)
            if not m.group().startswith(('//', '/*'))]


def close(t, i):
    opening = t[i][0]
    ending = {'(': ')', '[': ']', '{': '}'}[opening]
    depth = 1
    i += 1
    while depth:
        if t[i][0] == opening:
            depth += 1
        if t[i][0] == ending:
            depth -= 1
        i += 1
    return i


def statement(t, i):
    kind = t[i][0]
    if kind == 'begin':
        i += 1
        if t[i][0] == ':':
            i += 2
        while t[i][0] != 'end':
            i = statement(t, i)
        return i + 1
    if kind == 'if':
        i = statement(t, close(t, i + 1))
        return statement(t, i + 1) if t[i][0] == 'else' else i
    if kind in ('for', 'while', 'repeat'):
        return statement(t, close(t, i + 1))
    if kind in ('case', 'casez'):
        i = close(t, i + 1)
        while t[i][0] != 'endcase':
            while t[i][0] != ':':
                i += 1
            i = statement(t, i + 1)
        return i + 1
    while t[i][0] != ';':
        i += 1
    return i + 1


MIXED = {'instrument_production_link', 'song_uploaded_player', 'v3_analog_input'}
CDC = {'audio_sample_cdc', 'status_bundle_cdc', 'uart_byte_cdc'}
selected = {
    'additive_bank_32', 'audio_effects', 'audio_sample_cdc', 'audio_voice_mixer',
    'concurrent_test_source', 'expression_audition', 'hc05_commands',
    'instrument_control', 'instrument_production_link', 'key_debounce',
    'keyboard_note_events', 'note_event_voice', 'performance_controls',
    'physical_string_bank', 'physical_string_voice', 'pitch_expression',
    'polyphony_bank_32', 'reverb_comb', 'song_player', 'song_timeline',
    'song_timeline_rom', 'song_timing', 'song_uploaded_player',
    'status_bundle_cdc', 'string_pitch_control', 'uart_byte_cdc', 'v3_analog_input',
}
