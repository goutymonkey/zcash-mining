"""ZEQ-200X projection: one Equihash (200,9) instance per die, all tables in
on-die SRAM, P bucket-parallel engines (rtl/zeq_eh_par.v).

Inputs that are MEASURED here (not assumed):
  - rows per level at (200,9) and solutions per nonce (numpy model)
  - storage per instance with the bucketed layout (par_model.storage_bits)
  - engine cycles per row (RTL simulation, passed on the command line)
Inputs that are ASSUMED (7 nm class; every one is a parameter with a
low/typ/high range, printed with the results):
  SRAM density and energy, wire energy, Blake2b energy, logic energy,
  SRAM leakage, clock.

The shared expansion unit is serial: its busy cycles per attempt do not
shrink with the engine count. Pass the measured figure with
--expansion-cycles (tb_par writes expansion_profile.csv); the last round
cannot end before the unit is idle. Without it the projection omits that
cost and is optimistic at high engine counts.

usage: python3 arch_model.py --c-row 11.7 --engines 256 --expansion-cycles 300000
"""
import argparse
import math

# ---- measured at (200,9), GMAX 16 (see README / yield_check.py)
ROWS = [2097152, 2094116, 2090473, 2082351, 2065058, 2030574, 1964089, 1836414, 1607468]
SOLS_PER_NONCE = 1.42          # near-complete solver, 12 nonces
N, K, CB = 200, 9, 20
BB, SLOTS = 12, 640            # 4096 buckets, 640 slots (1.25x average)
STORAGE_MB = 134               # par_model.storage_bits(optimized), slots=640
HASHES = (1 << 21) // 2        # two leaves per 50-byte digest
HASH_CYCLES = 29               # engine cycles per group, one unit (mainnet RTL: 29.0;
                               # 14.5 with two units, 7.25 with four)
LEAF_SEND_CYCLES = 4.0         # floor per group: wait state + two leaves + advance,
                               # no contention; not reached in simulation (<= 4 units)

# ---- 7 nm assumptions: (low, typ, high)
TECH = {
    "sram_um2_per_bit": (0.035, 0.045, 0.060),   # HD bitcell 0.027 + periphery
    "sram_pj_per_bit":  (0.010, 0.020, 0.040),   # 32-128 KB macro access
    "wire_pj_bit_mm":   (0.05, 0.08, 0.15),      # repeated global wire
    "blake_nj":         (0.4, 0.8, 1.5),         # one Blake2b compression
    "logic_pj_row":     (2.0, 5.0, 10.0),        # engine control per row
    "leak_mw_per_mb":   (5.0, 15.0, 30.0),       # HD SRAM leakage
    "engine_mm2":       (0.03, 0.05, 0.08),      # engine + Blake2b + local tables
    "blake_mm2":        (0.008, 0.015, 0.025),   # each extra Blake2b unit (unsynthesized guess)
    "ghz":              (1.2, 1.0, 0.8),         # low column = optimistic
    "wafer_usd":        (9000, 10000, 12000),    # 300 mm wafer, 7 nm class
    "yield":            (0.85, 0.75, 0.60),      # die yield
}
LOW_SWING = 0.3   # --low-swing: crossbar wire energy x0.3 (low-swing signaling)


def project(c_row, engines, t, low_swing=False, expansion_cycles=0.0, hash_units=1):
    P = engines
    nb = 1 << BB
    lb = CB - BB
    # cycles per attempt: rows, per-bucket prefix sums, leaf hashing
    rows_total = sum(ROWS)
    cyc_rows = rows_total * c_row / P
    cyc_psum = K * nb * (1 << lb) / P     # one histogram entry per cycle
    # Leaf generation per group: the Blake2b wait shared over the engine's
    # units, floored by the time to send the group's leaves (SPLIT=1).
    cyc_hash = HASHES * max(HASH_CYCLES / hash_units, LEAF_SEND_CYCLES) / P
    cycles = cyc_rows + cyc_psum + cyc_hash
    # Serial expansion overlaps the last round's parallel work; only the
    # excess extends the attempt (the round barrier waits for the unit).
    last_round = ROWS[K - 1] * c_row / P + nb * (1 << lb) / P
    cycles += max(0.0, expansion_cycles - last_round)
    t_att = cycles / (t["ghz"] * 1e9)
    sol_s = SOLS_PER_NONCE / t_att

    # area
    sram_mm2 = STORAGE_MB * 8e6 * t["sram_um2_per_bit"] / 1e6
    logic_mm2 = P * (t["engine_mm2"] + (hash_units - 1) * t["blake_mm2"])
    xbar_mm2 = 0.002 * P * math.log2(P)            # multistage network
    die_mm2 = (sram_mm2 + logic_mm2 + xbar_mm2) * 1.15   # + I/O, power, spare
    side_mm = math.sqrt(die_mm2)

    # energy per attempt
    bits_sram = 0.0
    bits_move = 0.0
    for r in range(1, K + 1):
        w_in = N - (r - 1) * CB - BB
        rows_in = ROWS[r - 1]
        sb = math.ceil(math.log2(SLOTS)) + 1
        # v3 engine: SC reads the key, WK reads value + key (no LOAD pass)
        bits_sram += rows_in * (w_in + 2 * lb + 2 * sb)   # + order write/read
        if r < K:
            w_out = N - r * CB - BB
            pw = BB + 2 * math.ceil(math.log2(SLOTS))
            rows_out = ROWS[r]
            bits_sram += rows_out * (w_out + pw + lb + 2 * sb)  # row, ptr, key, hist RMW
            bits_move += rows_out * (w_out + pw + BB + lb)      # through the crossbar
    bits_sram += ROWS[0] * (N - BB + CB + 1 + lb + 2 * sb)     # level-0 writes
    bits_move += ROWS[0] * (N - BB + CB + 1 + lb)
    dist_mm = side_mm / 3 * 2                             # mean Manhattan hop
    e_sram = bits_sram * t["sram_pj_per_bit"] * 1e-12
    e_wire = bits_move * t["wire_pj_bit_mm"] * dist_mm * 1e-12 * (LOW_SWING if low_swing else 1.0)
    e_hash = HASHES * t["blake_nj"] * 1e-9
    e_logic = sum(ROWS) * t["logic_pj_row"] * 1e-12
    p_leak = STORAGE_MB * t["leak_mw_per_mb"] * 1e-3
    e_leak = p_leak * t_att
    e_att = e_sram + e_wire + e_hash + e_logic + e_leak
    mj_sol = e_att / SOLS_PER_NONCE * 1e3
    # silicon cost: gross dies on a 300 mm wafer (edge loss), times yield
    gross = math.pi * 150 ** 2 / die_mm2 - math.pi * 300 / math.sqrt(2 * die_mm2)
    usd_die = t["wafer_usd"] / (gross * t["yield"])
    return dict(cycles=cycles, sol_s=sol_s, die=die_mm2, sram=sram_mm2, logic=logic_mm2,
                usd_die=usd_die,
                watts=e_att / t_att, mj_sol=mj_sol,
                parts=dict(sram=e_sram, wire=e_wire, hash=e_hash, logic=e_logic, leak=e_leak),
                e_att=e_att)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--c-row", type=float, required=True, help="engine cycles per row (RTL)")
    ap.add_argument("--engines", type=int, default=256)
    ap.add_argument("--low-swing", action="store_true", help="low-swing crossbar signaling")
    ap.add_argument("--hash-units", type=int, default=1,
                    help="Blake2b units per engine (RTL HASH_UNITS)")
    ap.add_argument("--expansion-cycles", type=float, default=0.0,
                    help="measured serial expansion-unit busy cycles per attempt (expansion_profile.csv)")
    a = ap.parse_args()
    print("EXPLORATORY ONLY: assumes unimplemented packed storage and multistage network.")
    print("For current RTL memory/network inventory run model/production_budget.py.\n")
    print("ZEQ-200X projection, (200,9), %d engines, %.2f cycles/row/engine%s" % (
        a.engines, a.c_row, ", low-swing crossbar" if a.low_swing else ""))
    if a.expansion_cycles < 0 or a.hash_units < 1:
        ap.error("expansion cycles cannot be negative; hash units must be positive")
    print("leaf hashing: %d Blake2b unit(s) per engine" % a.hash_units)
    print("serial expansion: %s" % ("%.0f busy cycles/attempt (measured input)" % a.expansion_cycles
          if a.expansion_cycles else "NOT MODELED; throughput is optimistic at high engine counts"))
    print("%-6s %9s %9s %8s %7s %8s        energy split (sram/wire/hash/logic/leak)" % (
        "corner", "Mcyc/att", "Sol/s/die", "die mm2", "W/die", "mJ/Sol"))
    for i, name in enumerate(("best", "typ", "worst")):
        t = {k: v[i] for k, v in TECH.items()}
        r = project(a.c_row, a.engines, t, a.low_swing, a.expansion_cycles, a.hash_units)
        split = "/".join("%.0f%%" % (100 * v / r["e_att"]) for v in r["parts"].values())
        print("%-6s %9.2f %9.0f %8.0f %7.1f %8.2f        %s" % (
            name, r["cycles"] / 1e6, r["sol_s"], r["die"], r["watts"], r["mj_sol"], split))
    t = {k: v[1] for k, v in TECH.items()}
    r = project(a.c_row, a.engines, t, a.low_swing, a.expansion_cycles, a.hash_units)
    print("\ntyp: die area %.0f mm2, ~$.0f each; silicon cost excludes package, boards, PSU, NRE" % (
        r["die"], r["usd_die"]))


if __name__ == "__main__":
    main()
