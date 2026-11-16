import copy
from pathlib import Path
import tempfile
import unittest

import solver_boundary as boundary


class BoundaryTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.ports = {'clk': ('input', 1), 'done': ('output', 1)}
        self.memory = {'parameters': {'RD_PORTS': '1', 'WR_PORTS': '1', 'WIDTH': '8',
                                     'ABITS': '4', 'RD_TRANSPARENCY_MASK': "1'0", 'INIT': "128'x"},
                       'connections': {'RD_ADDR', 'RD_ARST', 'RD_CLK', 'RD_DATA', 'RD_EN',
                                       'RD_SRST', 'WR_ADDR', 'WR_CLK', 'WR_DATA', 'WR_EN'}}
        self.memories = {'g_eng[0].m_idx.mem': self.memory}
        self.expected = boundary.expected_boundary(self.ports, self.memories)

    def write(self, name, ports, memories):
        lines = ['module \\zeq_eh_par']
        for i, (port, (direction, width)) in enumerate(ports.items(), 1):
            lines.append(f'  wire width {width} {direction} {i} \\{port}')
        for name_, memory in memories.items():
            lines.append('  cell $mem_v2 \\' + name_)
            lines.extend(f'    parameter \\{key} {value}' for key, value in memory['parameters'].items())
            lines.extend('    connect \\' + key + " 1'0" for key in sorted(memory['connections']))
            lines.append('  end')
        lines.append('end')
        path = self.root/name
        path.write_text('\n'.join(lines) + '\n')
        return path

    def run_audit(self, raw_gate=None, gate_ports=None, norm_ports=None, norm_memories=None):
        return boundary.audit(self.write('gold.il', self.ports, self.memories),
                              self.write('gate.il', self.ports if gate_ports is None else gate_ports,
                                         self.memories if raw_gate is None else raw_gate),
                              self.write('gold-normalized.il', self.expected, {}),
                              self.write('gate-normalized.il', self.expected if norm_ports is None else norm_ports,
                                         {} if norm_memories is None else norm_memories), 1)

    def test_all_macro_signals_are_required(self):
        self.assertEqual(self.run_audit()['proof_ports'], 12)
        for suffix in self.memory['connections']:
            with self.subTest(port=suffix):
                ports = dict(self.expected)
                del ports['g_eng[0].m_idx.mem.' + suffix]
                with self.assertRaises(ValueError):
                    self.run_audit(norm_ports=ports)

    def test_changed_collision_semantics_are_rejected(self):
        memories = copy.deepcopy(self.memories)
        memories['g_eng[0].m_idx.mem']['parameters']['RD_TRANSPARENCY_MASK'] = "1'1"
        with self.assertRaises(ValueError):
            self.run_audit(raw_gate=memories)

    def test_changed_initial_state_is_rejected(self):
        memories = copy.deepcopy(self.memories)
        memories['g_eng[0].m_idx.mem']['parameters']['INIT'] = "128'0"
        with self.assertRaises(ValueError):
            self.run_audit(raw_gate=memories)

    def test_wrong_direction_or_width_is_rejected(self):
        for value in [('output', 8), ('input', 7)]:
            with self.subTest(value=value):
                ports = dict(self.expected)
                ports['g_eng[0].m_idx.mem.RD_DATA'] = value
                with self.assertRaises(ValueError):
                    self.run_audit(norm_ports=ports)

    def test_omitted_top_output_is_rejected(self):
        ports = dict(self.expected)
        del ports['done']
        with self.assertRaises(ValueError):
            self.run_audit(norm_ports=ports)

    def test_unexposed_memory_is_rejected(self):
        with self.assertRaises(ValueError):
            self.run_audit(norm_memories=self.memories)

    def test_unexpected_generic_internal_memory_is_rejected(self):
        memories = copy.deepcopy(self.memories)
        memories['fill'] = copy.deepcopy(self.memory)
        with self.assertRaises(ValueError):
            self.run_audit(raw_gate=memories)

    def test_truncated_netlist_is_rejected(self):
        path = self.write('truncated.il', self.ports, self.memories)
        path.write_text(path.read_text().rsplit('end', 1)[0])
        with self.assertRaises(ValueError):
            boundary.read_design(path)

    def test_scalar_boundary_requires_every_bit_and_direction(self):
        ports=boundary.scalar_boundary(self.expected)
        def check(candidate):
            return boundary.audit(self.write('raw-gold.il',self.ports,self.memories),
                self.write('raw-gate.il',self.ports,self.memories),
                self.write('scalar-gold.il',ports,{}),self.write('scalar-gate.il',candidate,{}),
                1,scalarized=True)
        self.assertEqual(check(ports)['proof_ports'],sum(w for d,w in self.expected.values()))
        for pin in ports:
            candidate=dict(ports);del candidate[pin]
            with self.subTest(pin=pin), self.assertRaises(ValueError):check(candidate)
        candidate=dict(ports);candidate['g_eng[0].m_idx.mem.RD_DATA[7]']=('output',1)
        with self.assertRaises(ValueError):check(candidate)
        candidate=dict(ports);candidate['extra[0]']=('output',1)
        with self.assertRaises(ValueError):check(candidate)

    def test_noncanonical_bus_indexing_is_rejected(self):
        for modifier in ['offset 3','upto']:
            path=self.write('indexed.il',self.ports,self.memories)
            path.write_text(path.read_text().replace('wire width 1 input',f'wire width 1 {modifier} input'))
            with self.subTest(modifier=modifier), self.assertRaises(ValueError):
                boundary.read_design(path)

    def test_scalar_index_metadata_must_agree_with_its_name(self):
        path=self.write('scalar.il',{'data[3]':('output',1)}, {})
        text=path.read_text().replace('wire width 1 output','wire offset 3 output')
        path.write_text(text)
        self.assertEqual(boundary.read_design(path,scalarized=True)[0],{'data[3]':('output',1)})
        with self.assertRaises(ValueError):boundary.read_design(path)
        path.write_text(text.replace('offset 3','offset 4'))
        with self.assertRaises(ValueError):boundary.read_design(path,scalarized=True)

    def test_scalar_expansion_rejects_name_collisions(self):
        with self.assertRaises(ValueError):
            boundary.scalar_boundary({'q':('output',2),'q[0]':('output',1)})

    def test_zero_memories_cannot_satisfy_the_solver_gate(self):
        with self.assertRaises(ValueError):
            boundary.audit(None, None, None, None, 0)


if __name__ == '__main__':
    unittest.main()
