"""Coverage controls: compression may neither add nor drop timing endpoints."""
import unittest
from compact_queries import compact_instance_paths, module_ports

class CoverageTests(unittest.TestCase):
    def test_safe_subtree_merges(self):
        patterns, matched = compact_instance_paths(['top/slow/a','top/slow/b'],
            {'top/slow/a','top/slow/b','top/fast/c'})
        self.assertEqual(patterns,['top/slow/*'])
        self.assertEqual(matched,{'top/slow/a','top/slow/b'})

    def test_full_speed_sibling_blocks_merge(self):
        patterns, _ = compact_instance_paths(['top/slow/a','top/slow/b'],
            {'top/slow/a','top/slow/b','top/slow/full_speed'})
        self.assertEqual(set(patterns),{'top/slow/a','top/slow/b'})

    def test_cross_hierarchy_descendant_blocks_merge(self):
        patterns, _ = compact_instance_paths(['top/slow/a','top/slow/b'],
            {'top/slow/a','top/slow/b','top/slow/child/full_speed'})
        self.assertNotIn('top/slow/*',patterns)

    def test_bus_named_instances_keep_coverage(self):
        patterns, matched = compact_instance_paths(['top/lanes?0?/x','top/lanes?1?/x'],
            {'top/lanes[0]/x','top/lanes[1]/x','top/lanes[2]/x'})
        self.assertEqual(matched,{'top/lanes[0]/x','top/lanes[1]/x'})
        self.assertNotIn('top/*',patterns)

    def test_empty_query_is_rejected(self):
        with self.assertRaises(ValueError): compact_instance_paths(['missing'],{'top/a'})

    def test_port_universe_includes_control_and_bus_bits(self):
        pins = module_ports('module m; // input fake;\ninput [2:0] A; input ASEL, CLK, CE; output DOUT; endmodule')
        self.assertEqual(pins,{'A[0]','A[1]','A[2]','ASEL','CLK','CE','DOUT'})

if __name__ == '__main__': unittest.main(verbosity=2)
