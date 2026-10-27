"""Check cross-hierarchy feedback proof against the current synthesized netlist."""
import argparse
import re
import unittest
import audit_half_rate as audit
from test_half_rate_audit import NetlistText


class HierarchyTests(unittest.TestCase):
    def check_netlist(self, text):
        return audit.netlist_audit(NetlistText(text), PROCESSES, contest_strings=True)

    def test_actual_hierarchy_and_sample_ce(self):
        result = self.check_netlist(NETLIST)
        self.assertIn('u_instrument/engine_sample_q_s0', result['half_rate_ffs'])
        self.assertEqual(len(result['independent_phases']), 32)
        self.assertEqual(result['independent_voice_instances']['physical_string_voice'], 8)

    def test_feedback_stuck_high_is_rejected(self):
        self.check_broken_feedback('VCC')

    def test_feedback_stuck_low_is_rejected(self):
        self.check_broken_feedback('GND')

    def check_broken_feedback(self, value):
        # The actual feedback inverter was moved inside the PT8211 hierarchy.
        pattern = r'(INV n311_s4 \(\s*\.O\(n311_9\),\s*\.I\()half_tick(\))'
        broken, count = re.subn(pattern, lambda m: m[1]+value+m[2], NETLIST)
        self.assertEqual(count, 1, 'Update the fixture only after reviewing new mapping')
        with self.assertRaisesRegex(ValueError, 'does not invert'):
            self.check_netlist(broken)

    def test_unqualified_sample_is_excluded(self):
        pattern = r'(DFFCE engine_sample_q_s0 \(.*?\.CE\()half_tick_10(\))'
        broken, count = re.subn(pattern, lambda m: m[1]+'VCC'+m[2], NETLIST, flags=re.S)
        self.assertEqual(count, 1)
        self.assertNotIn('u_instrument/engine_sample_q_s0',
                         self.check_netlist(broken)['half_rate_ffs'])


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--netlist', required=True, type=audit.Path)
    args = parser.parse_args()
    NETLIST = args.netlist.read_text(encoding='utf-8-sig')
    PROCESSES = audit.source_processes()
    unittest.main(argv=['test_half_tick_hierarchy'], verbosity=2)
