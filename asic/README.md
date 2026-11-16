# ZEQ-HB4: Equihash hashboard in tscircuit

A 4-chip Zcash (Equihash 200,9) mining hashboard, written as TSX with
[tscircuit](https://tscircuit.com). The chips are stacked in series voltage
domains, the way commercial hashboards are built.

**The chip.** tscircuit designs boards, not silicon. The ZEQ-200 chip itself
is designed separately, as synthesizable Verilog in [`chip/`](chip/): a
Blake2b leaf-hash core, a hardware Wagner solver, and the chain protocol
this board wires up. It's verified bit for bit against a reference model
and zcash's own solution verifier, including a simulation of four chips
chained exactly like this board. `lib/ZeqAsic.tsx` is its package and
pinout, and `chip/rtl/zeq200.v` has the same pins. It hasn't been fabbed;
[chip/README.md](chip/README.md) covers what that would take.

## Architecture

```
12V ─► 2mΩ shunt (INA219) ─► buck ─► VSTRING = 4 × 0.8V = 3.2V

VSTRING ─┬─ U4 ─ DOM3 ─ U3 ─ DOM2 ─ U2 ─ DOM1 ─ U1 ─┬─ GND
         (one current flows through all four chips in series)

per domain k:  LP2985-18 (12V via 10Ω, GND = DOMk) ─► VDDIOk 1.8V
               SiT8008 25 MHz ─33Ω─► Uk.CLKI       (no clock crosses domains)
between domains (3× ISO6721 digital isolators per boundary):
               CO ─► CI, RSTO ─► RSTN      (commands and reset, going up)
               RO ◄─ RO, BI ◄─ BO          (results and busy, coming down)
               OT ◄─ OT via Schottky       (over-temperature, wire-OR down)
domain 0 ◄─► TXS0108 (1.8V ↔ 3.3V) ◄─► CN_CTRL: TX, RX, RST, BUSY, OT_N
TPS3808 watches VSTRING ─► PGOOD;  CN_CTRL VCORE_EN gates the buck
I2C: TMP75 (0x48, ALERT to CN_CTRL), INA219 (0x41), AT24C02 EEPROM (0x50)
```

### Why stack

With the chips in parallel, the buck has to deliver the combined current of
every chip at 0.8V. In series, the same current flows through each chip in
turn, so the buck delivers one chip's worth of current at 4× the voltage.
The stack grows with the board: at 15 domains, VSTRING = 12V and the string
runs straight off the PSU with no buck at all. `DOMAINS` in `lib/stack.tsx`
sets the count.

Stacking has a cost. Each domain's ground sits 0.8V above the one below it,
so nothing can connect across a boundary with a plain wire:

- **IO power:** each domain has its own LP2985-18 LDO, fed from 12V through a
  10 Ω + 1 µF RC filter and referenced to that domain's ground. It's
  rated to 16V in, so every domain in a 15-domain string still fits.
- **Clock:** each domain has its own 25 MHz oscillator, so no clock crosses a
  boundary. The chips' UARTs tolerate the few-ppm offset between oscillators.
- **Chain signals:** these cross through ISO6721 isolators, which handle any
  ground offset and run at 1.8V on both sides.
- **Over-temperature:** each isolator output is push-pull, so a Schottky
  turns it back into a pull-down. Any chip can then pull the domain-0 line
  low.

### Board

- 4-layer board, 170×100 mm. GND pour on inner1, plus a separate pour for
  each domain on inner2 and bottom under its chip
- ZEQ-200 pins are grouped by side: chain inputs face the previous chip,
  outputs face the next, core power faces the core caps, and IO power
  faces the IO cap. No chain signal has to cross under a package.
- The whole bottom edge is VDD (6 pins), and the exposed pad is the main
  ground. In a stack, VDD and VSS are both wide domain rails, and wide
  traces on alternating 0.5 mm-pitch pins can't be routed.
- Trace widths: 1 mm on the 12V and switch-node nets, 0.6 mm on VSTRING and
  each domain rail, 0.5 mm on GND, 0.3 mm on 3V3, and the router's default
  elsewhere
- Thermal: a 3×3 via array in each exposed pad, connected to that chip's
  domain rail, not GND
- Stitching: a ring of GND vias 3 mm in from the board edge
- Per-chip decoupling across the domain: 2×22 µF + 1 µF core, 100 nF IO
- VSTRING = 0.6 V × (1 + 43.2k/10k) ≈ 3.19 V (R_FB1/R_FB2); PGOOD trips
  below 0.405 V × (1 + 61.9k/10k) ≈ 2.91 V
- ESD: two SRV05-4 arrays on 8 controller signals (all except PGOOD and
  VCORE_EN)
- Four M3 mounting holes (3.2 mm)

### Controller connector (CN_CTRL, 2×8)

| Pin | Signal | Pin | Signal |
|---|---|---|---|
| 1 | 3V3 | 2 | 3V3 |
| 3 | GND | 4 | GND |
| 5 | TX (to chain) | 6 | RX (from chain) |
| 7 | RST | 8 | BUSY |
| 9 | SDA | 10 | SCL |
| 11 | PGOOD | 12 | VCORE_EN |
| 13 | OT_N (any chip over temp) | 14 | ALERT (TMP75) |
| 15 | GND | 16 | GND |

## Build

```sh
npm install
npm run build                      # -> dist/index/{circuit.json,pcb.png,schematic.png}
npx tsci dev                       # browser preview (schematic/PCB/3D)
npx tsci export index.circuit.tsx -f gerbers   # fab outputs
```

Gerbers, KiCad exports and rendered outputs are generated locally and are
excluded from Git. A fresh clone includes the design sources, not a
pre-exported fabrication package. Validate the generated output before use.

`bun` is installed as a dev dependency because the `tsci` CLI runs on it.
Autorouting takes about 2 minutes. Current result: 169 traces and 139 vias,
with 0 DRC errors. Don't add `schX`/`schY` to only some parts: this
tscircuit version hangs in schematic layout when fixed and auto-placed
parts are mixed.

## Not production-ready

- Nothing balances the domains yet. The chips in a series stack have to
  draw matching current, or the domain voltages drift apart. Commercial
  boards trim each chip's frequency and voltage in firmware to keep them
  even. This board has no per-domain voltage monitor to do that with.
- The router wires the domain rails with traces as well as reaching the
  pours. A hand layout would drop most of those traces.
- The schematic uses a plain grid layout (`schGrid`), because tscircuit's
  automatic schematic placement slows to minutes past about 150 parts.
- Check every real part's pinout against its datasheet before fab.
  ISO6721, LP2985, TPS3808, SRV05-4, TXS0108, INA219, AT24C02 and TMP75
  were entered by hand, and the fab files are only as right as those
  pin maps.
- The ZEQ-200 exists as verified RTL, not silicon, so its voltages and
  current draw are design targets, not measurements.
- Even stacked, a real Equihash chip's current is more than one SOIC-8 buck
  can supply. A real board would use more domains running directly off the
  PSU, plus a heatsink and airflow.
- The control side (stratum, work dispatch) runs on a separate controller
  board over CN_CTRL. It would speak the protocol in
  [chip/README.md](chip/README.md), with the host logic in `../src/`
  (stratum, header building, `--verify`).
  A production ASIC UART driver, bounded frame recovery and worst-case
  inter-byte gaps remain to be qualified. Multiple four-address chains
  must receive distinct work so that repeated strap addresses do not mine
  duplicate nonce ranges. Production power delivery, domain monitoring and
  balancing, package and cooling must be selected from characterized die
  requirements; the existing board is a demonstrator design.

## License

The board sources and package retain their existing [ISC license](../LICENSES/ISC.txt).
The chip RTL and engineering software have separate terms; see the
[repository license map](../LICENSING.md). The package's `private: true`
setting prevents accidental npm publication and does not control GitHub
visibility.
