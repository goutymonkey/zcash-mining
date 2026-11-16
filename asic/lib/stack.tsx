import { Fragment } from "react"
import { ZeqAsic } from "./ZeqAsic"

/**
 * Series-stacked ASIC string.
 *
 * Each ZEQ-200 sits in its own voltage domain. Domain k runs from D[k]
 * (its local ground) to D[k+1] (its core supply), so the string is fed
 * from one supply at DOMAINS x VCORE and every chip shares the same current.
 * With 15 domains the string runs straight off a 12V PSU with no buck at all.
 *
 * Because each domain's ground is 0.8V above the one below, nothing that
 * crosses a domain boundary can be a plain wire:
 * - VDDIO comes from a per-domain LP2985-18 LDO fed from 12V (through a 10R
 *   RC filter) and referenced to the domain's own ground
 * - each domain has its own 25 MHz oscillator (no clock crosses a boundary)
 * - CI/RSTN (down the chain) and RO/BO/OT (up) cross through ISO6721
 *   digital isolators
 * - over-temp flags chain toward domain 0 through a Schottky per boundary,
 *   so any chip can pull the domain-0 OT line low
 */
export const DOMAINS = 4
export const VCORE_PER_DOMAIN = 0.8
export const CHIP_Y = 16
const PITCH = 32
export const chipX = (k: number) => -60 + k * PITCH
const POUR_HALF = 14

/** Domain k's ground rail; D[0] is board GND and D[DOMAINS] is VSTRING. */
export const domNet = (k: number) =>
  k === 0 ? "GND" : k === DOMAINS ? "VSTRING" : `D${k}`
const n = (name: string) => `net.${name}`
const vddio = (k: number) => `VDDIO${k}`
const ot = (k: number) => (k === 0 ? "OT_1V8" : `OT${k}`)
const chip = (k: number) => `U${k + 1}`

export const stackNetNames = Array.from(
  { length: DOMAINS + 1 },
  (_, k) => domNet(k),
).filter((name) => name !== "GND")

// 3x3 via-in-pad array under each exposed pad, into that domain's pours
const THERMAL_VIA_OFFSETS = [-0.8, 0, 0.8]

type ViaSpec = {
  pcbX: number
  pcbY: number
  holeDiameter: string
  outerDiameter: string
  connectsTo: string
}
const Via = (props: ViaSpec) => <via {...props} />

type IsoSpec = {
  name: string
  pcbX: number
  pcbY: number
  // side 1 = lower domain, side 2 = upper domain
  lower: number
  inA?: string
  outA?: string
  inB?: string
  outB?: string
}

/** TI ISO6721: 1 channel lower->upper (A), 1 channel upper->lower (B). */
const Isolator = ({ name, pcbX, pcbY, lower, inA, outA, inB, outB }: IsoSpec) => (
  <>
    <chip
      name={name}
      manufacturerPartNumber="ISO6721DR"
      footprint="soic8"
      pinLabels={{
        pin1: "VCC1",
        pin2: "INA",
        pin3: "OUTB",
        pin4: "GND1",
        pin5: "GND2",
        pin6: "INB",
        pin7: "OUTA",
        pin8: "VCC2",
      }}
      pcbX={pcbX}
      pcbY={pcbY}
      connections={{
        VCC1: n(vddio(lower)),
        GND1: n(domNet(lower)),
        VCC2: n(vddio(lower + 1)),
        GND2: n(domNet(lower + 1)),
        // unused inputs are tied to their own side's ground
        INA: inA ?? n(domNet(lower)),
        INB: inB ?? n(domNet(lower + 1)),
        ...(outA ? { OUTA: outA } : {}),
        ...(outB ? { OUTB: outB } : {}),
      }}
    />
    {/* decoupling sits in the gap below the package, not beside it: the
        sides are where the chain signals fan in */}
    <capacitor
      name={`${name}_C1`}
      capacitance="100nF"
      footprint="0402"
      pcbX={pcbX - 1.3}
      pcbY={pcbY - 4}
      connections={{ pin1: n(vddio(lower)), pin2: n(domNet(lower)) }}
    />
    <capacitor
      name={`${name}_C2`}
      capacitance="100nF"
      footprint="0402"
      pcbX={pcbX + 1.3}
      pcbY={pcbY - 4}
      connections={{ pin1: n(vddio(lower + 1)), pin2: n(domNet(lower + 1)) }}
    />
  </>
)

const Domain = ({ k }: { k: number }) => {
  const x = chipX(k)
  const y = CHIP_Y
  const gnd = domNet(k)
  const vdd = domNet(k + 1)
  const io = vddio(k)
  const isFirst = k === 0
  const isLast = k === DOMAINS - 1
  const U = chip(k)
  return (
    <>
      <ZeqAsic
        name={U}
        pcbX={x}
        pcbY={y}
        connections={{
          VDD1: n(vdd),
          VDD2: n(vdd),
          VDD3: n(vdd),
          VDD4: n(vdd),
          VDD5: n(vdd),
          VDD6: n(vdd),
          VSS: n(gnd),
          EPAD: n(gnd),
          VDDPLL: n(io),
          VDDIO1: n(io),
          VDDIO2: n(io),
          // chip address straps: 2 bits -> chips 0..3
          ADDR0: n(k & 1 ? io : gnd),
          ADDR1: n(k & 2 ? io : gnd),
          CLKI: n(`CLKI${k}`),
          // domain 0 talks to the controller; the rest via isolators below
          CI: n(isFirst ? "CI0" : `CI${k}`),
          RSTN: n(isFirst ? "RST_1V8" : `RSTN${k}`),
          RO: n(isFirst ? "RO_1V8" : `RO${k}`),
          BO: n(isFirst ? "BO_1V8" : `BO${k}`),
          // CO/RSTO/RI/BI of lower chips are wired by the bridge above them;
          // the top chip terminates the upstream chain
          ...(isLast ? { RI: n(io), BI: n(io) } : {}),
          TEMP: n(ot(k)),
        }}
      />

      {/* core decoupling across this domain: 2x 22uF + 1uF */}
      {[
        [`C${k + 1}1`, "22uF", "0805", -5],
        [`C${k + 1}2`, "22uF", "0805", 5],
        [`C${k + 1}3`, "1uF", "0402", 0],
      ].map(([name, capacitance, footprint, dx]) => (
        <capacitor
          key={name as string}
          name={name as string}
          capacitance={capacitance as string}
          footprint={footprint as string}
          pcbX={x + (dx as number)}
          pcbY={y - 9}
          connections={{ pin1: n(vdd), pin2: n(gnd) }}
        />
      ))}
      <capacitor
        name={`C${k + 1}4`}
        capacitance="100nF"
        footprint="0402"
        pcbX={x}
        pcbY={y + 7}
        connections={{ pin1: n(io), pin2: n(gnd) }}
      />

      {/* thermal vias into this domain's pours (not GND!) */}
      {THERMAL_VIA_OFFSETS.flatMap((dx) =>
        THERMAL_VIA_OFFSETS.map((dy) => (
          <Via
            key={`tv${dx},${dy}`}
            pcbX={x + dx}
            pcbY={y + dy}
            holeDiameter="0.3mm"
            outerDiameter="0.5mm"
            connectsTo={n(gnd)}
          />
        )),
      )}
      {/* per-domain copper on inner2 and bottom: heat spreading + rail */}
      {(["inner2", "bottom"] as const).map((layer) => (
        <Fragment key={layer}>
        <copperpour
          layer={layer}
          connectsTo={n(gnd)}
          outline={[
            { x: x - POUR_HALF, y: y - POUR_HALF },
            { x: x + POUR_HALF, y: y - POUR_HALF },
            { x: x + POUR_HALF, y: y + POUR_HALF },
            { x: x - POUR_HALF, y: y + POUR_HALF },
          ]}
        />
        </Fragment>
      ))}

      {/* local VDDIO: LP2985-18 from 12V, referenced to this domain.
          V12F is a thin 12V branch (split off at the input); 10R + 1uF
          per domain filters it and keeps wide copper off the SOT-23 pins */}
      <resistor
        name={`R_LDI${k}`}
        resistance="10"
        footprint="0603"
        pcbX={x - 11}
        pcbY={y + 19.5}
        connections={{ pin1: n("V12F"), pin2: n(`VLDO${k}`) }}
      />
      <chip
        name={`U_LDO${k}`}
        manufacturerPartNumber="LP2985-18DBVR"
        footprint="sot23_5"
        pinLabels={{
          pin1: "VIN",
          pin2: "GND",
          pin3: "ON",
          pin4: "BYPASS",
          pin5: "VOUT",
        }}
        pcbX={x - 6}
        pcbY={y + 15}
        connections={{
          VIN: n(`VLDO${k}`),
          ON: n(`VLDO${k}`),
          GND: n(gnd),
          BYPASS: n(`BYP${k}`),
          VOUT: n(io),
        }}
      />
      <capacitor
        name={`C_LDI${k}`}
        capacitance="1uF"
        footprint="0603"
        pcbX={x - 11}
        pcbY={y + 15}
        connections={{ pin1: n(`VLDO${k}`), pin2: n(gnd) }}
      />
      <capacitor
        name={`C_LDO${k}`}
        capacitance="2.2uF"
        footprint="0402"
        pcbX={x - 1.5}
        pcbY={y + 15}
        connections={{ pin1: n(io), pin2: n(gnd) }}
      />
      <capacitor
        name={`C_BYP${k}`}
        capacitance="10nF"
        footprint="0402"
        pcbX={x - 6}
        pcbY={y + 19.5}
        connections={{ pin1: n(`BYP${k}`), pin2: n(gnd) }}
      />

      {/* local 25 MHz reference, so no clock crosses a domain boundary */}
      <chip
        name={`OSC${k}`}
        manufacturerPartNumber="SiT8008BI-25MHz"
        footprint="sot23_5"
        pinLabels={{ pin1: "OE", pin2: "GND", pin3: "OUT", pin4: "NC", pin5: "VDD" }}
        pcbX={x + 6}
        pcbY={y + 15}
        connections={{
          OE: n(io),
          GND: n(gnd),
          OUT: n(`CLK${k}`),
          VDD: n(io),
        }}
      />
      <capacitor
        name={`C_OSC${k}`}
        capacitance="100nF"
        footprint="0402"
        pcbX={x + 10.5}
        pcbY={y + 15}
        connections={{ pin1: n(io), pin2: n(gnd) }}
      />
      <resistor
        name={`R_CK${k}`}
        resistance="33"
        footprint="0402"
        pcbX={x - 5}
        pcbY={y + 4}
        connections={{ pin1: n(`CLK${k}`), pin2: n(`CLKI${k}`) }}
      />

      {/* open-drain over-temp pull-up, kept below the right-side pins so the
          chain signals heading to the next bridge have a clear channel */}
      <resistor
        name={`R_OT${k}`}
        resistance="10k"
        footprint="0402"
        pcbX={x + 4}
        pcbY={y - 5.5}
        connections={{ pin1: n(ot(k)), pin2: n(io) }}
      />

      {isFirst ? (
        <resistor
          name="R_CI0"
          resistance="33"
          footprint="0402"
          pcbX={x - 7}
          pcbY={y}
          connections={{ pin1: n("CI_1V8"), pin2: n("CI0") }}
        />
      ) : (
        <DomainBridge k={k} />
      )}
    </>
  )
}

/** Isolators + OT diode between domain k-1 (below) and domain k (above). */
const DomainBridge = ({ k }: { k: number }) => {
  const bx = chipX(k) - PITCH / 2
  const y = CHIP_Y
  const lower = k - 1
  const below = chip(lower)
  return (
    <>
      <Isolator
        name={`U_ISO${k}A`}
        pcbX={bx}
        pcbY={y - 8}
        lower={lower}
        inA={`.${below} > .CO`}
        outA={n(`CI${k}`)}
        inB={n(`RO${k}`)}
        outB={`.${below} > .RI`}
      />
      <Isolator
        name={`U_ISO${k}B`}
        pcbX={bx}
        pcbY={y}
        lower={lower}
        inA={`.${below} > .RSTO`}
        outA={n(`RSTN${k}`)}
        inB={n(`BO${k}`)}
        outB={`.${below} > .BI`}
      />
      <Isolator
        name={`U_ISO${k}C`}
        pcbX={bx}
        pcbY={y + 8}
        lower={lower}
        inB={n(ot(k))}
        outB={n(`OTX${k}`)}
      />
      {/* isolator output is push-pull; the diode makes it pull-down only */}
      <diode
        name={`D_OT${k}`}
        footprint="sod123"
        pcbX={bx + 7}
        pcbY={y + 10}
        connections={{ anode: n(ot(lower)), cathode: n(`OTX${k}`) }}
      />
    </>
  )
}

export const AsicStack = () => (
  <>
    {Array.from({ length: DOMAINS }, (_, k) => (
      <Fragment key={k}>
        <Domain k={k} />
      </Fragment>
    ))}
  </>
)
