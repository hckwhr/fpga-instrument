"""Regression/negative controls for constraint generation, using the frozen netlist."""
import argparse
import re
import unittest
from pathlib import Path
import audit_half_rate as audit


class NetlistText:
    def __init__(self, text):
        self.text = text
    def read_text(self, **kwargs):
        return self.text
    def read_bytes(self):
        return self.text.encode('utf-8')


class AuditTests(unittest.TestCase):
    def test_header_does_not_eat_first_lut(self):
        body = "module example (\n clk\n)\n;\n  LUT1 first (\n .F(a),\n .I0(b)\n);\nendmodule"
        self.assertEqual(audit.parse_instances(body), [('LUT1','first',{'F':'a','I0':'b'})])

    def test_literal_bus_brackets(self):
        self.assertTrue(audit.object_matches('top/lanes[7].state_0', 'top/lanes[7].state*'))
        self.assertFalse(audit.object_matches('top/lanes[8].state_0', 'top/lanes[7].state*'))

    def test_real_proof_and_boundaries(self):
        result = audit.netlist_audit(NetlistText(NETLIST), PROCESSES, CONTEST_32)
        included = set(result['half_rate_ffs'])
        for bit in range(6):
            self.assertIn(f'u_instrument/u_concurrent_test_source/poly_index_{bit}_s0', included)
        self.assertEqual(result['manual_launch_patterns'], ['u_instrument/poly_enable_s46'])
        self.assertNotIn('u_instrument/poly_enable_s46', included)
        self.assertNotIn('u_instrument/audio_reset_sync_n_1_s0', included)
        self.assertFalse(any('/u_pt8211_tx/' in p or '/u_spectrum/' in p or
                             re.search(r'/strings\[\d+\]\.voice/',p) for p in included))
        self.assertEqual(len(result['independent_phases']),32)

    def test_non_gated_index_is_rejected(self):
        old = "poly_index_4_s2.INIT=16'h4F00"
        self.assertEqual(NETLIST.count(old),1)
        broken = NETLIST.replace(old, "poly_index_4_s2.INIT=16'h4F01")
        result = audit.netlist_audit(NetlistText(broken), PROCESSES, CONTEST_32)
        self.assertNotIn('u_instrument/u_concurrent_test_source/poly_index_2_s0',result['half_rate_ffs'])

    def test_replica_reset_mismatch_is_rejected(self):
        old = "poly_enable_s46.INIT=1'b0"
        self.assertEqual(NETLIST.count(old),1)
        result = audit.netlist_audit(NetlistText(NETLIST.replace(old,"poly_enable_s46.INIT=1'b1")),PROCESSES,CONTEST_32)
        self.assertEqual(result['manual_launch_patterns'],[])

    def test_replica_inactive_update_is_rejected(self):
        proof = audit.netlist_audit(NetlistText(NETLIST),PROCESSES,CONTEST_32)['manual_launch_proofs'][0]
        lut = proof['replicas'][0]['lut']
        old = lut + ".INIT=16'hBBF0"
        self.assertEqual(NETLIST.count(old),1)
        result = audit.netlist_audit(NetlistText(NETLIST.replace(old,lut+".INIT=16'hBBF1")),PROCESSES,CONTEST_32)
        self.assertEqual(result['manual_launch_patterns'],[])


if __name__ == '__main__':
    parser=argparse.ArgumentParser()
    parser.add_argument('--netlist',type=Path,required=True)
    parser.add_argument('--contest-32',action='store_true')
    args=parser.parse_args()
    NETLIST=args.netlist.read_text(encoding='utf-8-sig')
    CONTEST_32=args.contest_32
    PROCESSES=audit.source_processes()
    unittest.main(argv=['test_half_rate_audit'],verbosity=2)
