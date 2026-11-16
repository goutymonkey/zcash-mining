"""Throughput / bandwidth / energy model for the ZEQ-200 mainnet die,
calibrated from RTL simulation profiles (tb_solver3 at 200,9).

usage: python3 perf_model.py PROFILE [--sols-per-attempt S] [--f-ghz F]

Every number printed is derived from the measured profile plus the stated
assumptions below; change the assumptions on the command line.
"""
import argparse
import re

# Published reference points for external miners are intentionally omitted in the public snapshot.

# Assumptions (per access, per bit), stated so they can be challenged
DRAM_PJ_PER_BIT = 4.0     # LPDDR5 / HBM3 class interface + core energy
HBM3_STACK_GBPS = 819.0   # one HBM3 stack, 6.4 Gb/s x 1024 bits


def parse(path):
    txt = open(path).read()
    ports = {}
    for m in re.finditer(r"port (\w+)\s+reads (\d+) writes (\d+) \(width (\d+) bits\)", txt):
        ports[m.group(1)] = (int(m.group(2)), int(m.group(3)), int(m.group(4)))
    phases = dict((k, int(v)) for k, v in re.findall(r"(\w[\w+]*) (\d+)", txt.split("phase", 1)[1]))
    return ports, phases


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("profile")
    ap.add_argument("--sols-per-attempt", type=float, default=1.42,
                    help="measured with model/yield_check.py (near-complete solver)")
    ap.add_argument("--f-ghz", type=float, default=1.0, help="core clock of the mainnet die")
    a = ap.parse_args()

    ports, phases = parse(a.profile)
    cycles = sum(phases.values())
    byts = 0.0
    print("per attempt (one nonce), measured:")
    for name, (rd, wr, w) in ports.items():
        b = (rd + wr) * w / 8
        byts += b
        print("  %-4s %11d accesses x %3d bits = %8.1f MB" % (name, rd + wr, w, b / 1e6))
    print("  total table traffic            = %8.1f MB" % (byts / 1e6))
    print("  cycles                         = %8.1f M" % (cycles / 1e6))

    t_att = cycles / (a.f_ghz * 1e9)
    sols = a.sols_per_attempt
    per_lane_sols = sols / t_att
    bw_lane = byts / t_att / 1e9
    bytes_per_sol = byts / sols
    dram_mj = bytes_per_sol * 8 * DRAM_PJ_PER_BIT * 1e-12 * 1e3
    lanes_per_stack = HBM3_STACK_GBPS / bw_lane
    print()
    print("at %.2f GHz, %.2f solutions per attempt:" % (a.f_ghz, sols))
    print("  per lane: %.2f Sol/s, needs %.1f GB/s of table bandwidth" % (per_lane_sols, bw_lane))
    print("  bytes per solution: %.2f GB" % (bytes_per_sol / 1e9))
    print("  DRAM energy per solution (%.1f pJ/bit): %.1f mJ" % (DRAM_PJ_PER_BIT, dram_mj))
    print("  one HBM3 stack (%.0f GB/s) feeds %.0f lanes = %.0f Sol/s" % (
        HBM3_STACK_GBPS, lanes_per_stack, lanes_per_stack * per_lane_sols))


if __name__ == "__main__":
    main()
