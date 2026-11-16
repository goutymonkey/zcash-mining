#!/usr/bin/env python3
"""Full-scan insertion on a SKY130 gate-level netlist.

Every sky130_fd_sc_hd__dfxtp_N (D, CLK -> Q) becomes the scan flip-flop
sky130_fd_sc_hd__sdfxtp_N (adds SCD = scan data, SCE = scan enable), and
the flops are stitched into one chain: scan_in -> ff0.SCD, ffk.Q ->
ff(k+1).SCD, ff(last).Q -> scan_out. New module ports: scan_en, scan_in,
scan_out. With scan_en = 0 the circuit is unchanged (proved by
formal/lec_scan.ys); with scan_en = 1 the flops form a shift register
(checked by tb/tb_scan.sv).

usage: scan_insert.py in.v out.v top_module
"""
import re
import sys

src, dst, top = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(src).read()

inst_re = re.compile(
    r"sky130_fd_sc_hd__dfxtp_(\d+)\s+(\S+)\s*\((.*?)\);", re.S)
pin_re = re.compile(r"\.(\w+)\s*\(\s*(.*?)\s*\)\s*(?:,|$)", re.S)

flops = []


def rewrite(m):
    drive, name, body = m.group(1), m.group(2), m.group(3)
    # escaped identifiers (\name) must be followed by whitespace
    pins = dict((p, n + " " if n.startswith("\\") else n) for p, n in pin_re.findall(body))
    k = len(flops)
    flops.append((name, pins["Q"]))
    scd = "scan_in" if k == 0 else "\\scan_q_%d " % (k - 1)
    return ("sky130_fd_sc_hd__sdfxtp_%s %s (.CLK(%s), .D(%s), .SCD(%s), .SCE(scan_en), .Q(%s));"
            % (drive, name, pins["CLK"], pins["D"], scd, pins["Q"]))


out = inst_re.sub(rewrite, text)
if not flops:
    sys.exit("no dfxtp flops found")

# chain wires: scan_q_k aliases ff k's Q
chain = "\n".join("  wire \\scan_q_%d ;\n  assign \\scan_q_%d  = %s;" % (k, k, q)
                  for k, (_, q) in enumerate(flops))
chain += "\n  assign scan_out = \\scan_q_%d ;\n" % (len(flops) - 1)

# add ports to the top module header and declarations
hdr = re.compile(r"(module\s+%s\s*\()" % re.escape(top))
out, n = hdr.subn(r"\1scan_en, scan_in, scan_out, ", out, count=1)
if n != 1:
    sys.exit("top module %s not found" % top)
body_start = out.index(";", out.index("module %s" % top)) + 1
decl = "\n  input scan_en;\n  input scan_in;\n  output scan_out;\n"
out = out[:body_start] + decl + out[body_start:]
end = out.index("endmodule", body_start)
out = out[:end] + chain + out[end:]
open(dst, "w").write(out)
print("scan chain: %d flops" % len(flops))
