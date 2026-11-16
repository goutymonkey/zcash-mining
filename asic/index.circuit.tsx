import { Fragment } from "react"
import { AsicStack, stackNetNames } from "./lib/stack"

/**
 * ZEQ-HB4: a 4-domain Equihash (200,9) hashboard.
 *
 *  12V -> shunt (INA219) -> buck -> VSTRING = DOMAINS x 0.8V = 3.2V
 *  VSTRING feeds a series stack: GND | U1 | DOM1 | U2 | DOM2 | U3 | DOM3 | U4
 *  each domain: own LDO (VDDIO from 12V), own 25 MHz oscillator
 *  domain-to-domain chain signals cross through ISO6721 isolators
 *  controller UART/RST/BUSY/OT (3.3V) <-> TXS0108 <-> domain 0 (1.8V)
 *  VSTRING supervisor -> PGOOD; EEPROM for board ID and calibration
 */
// thin wrappers so vias/holes can be keyed inside .map()
type ViaSpec = {
  pcbX: number
  pcbY: number
  holeDiameter: string
  outerDiameter: string
  connectsTo: string
}
const Via = (props: ViaSpec) => <via {...props} />
const Hole = (props: { pcbX: number; pcbY: number; diameter: string }) => (
  <hole {...props} />
)


// GND stitching ring, 3 mm in from the edge (board is 170 x 100 mm)
const range = (from: number, to: number, step: number) =>
  Array.from({ length: Math.floor((to - from) / step) + 1 }, (_, i) => from + i * step)
const stitchPoints = [
  ...range(-70, 70, 10).flatMap((x) => [
    [x, 47],
    [x, -47],
  ]),
  ...range(-40, 40, 10).flatMap((y) => [
    [-82, y],
    [82, y],
  ]),
]
const MOUNT_HOLES = [
  [-81, 46],
  [81, 46],
  [-81, -46],
  [81, -46],
]

export default () => (
  <board width="170mm" height="100mm" layers={4} schGrid>
    {/* schGrid: auto schematic placement scales badly past ~150 parts */}
    {/* power nets get wide traces; the QFN pins neck down at the pad */}
    <net name="V12_IN" isPowerNet nominalTraceWidth="1mm" />
    <net name="V12" isPowerNet nominalTraceWidth="1mm" />
    <net name="SW" nominalTraceWidth="1mm" />
    {stackNetNames.map((name) => (
      <Fragment key={name}>
        <net name={name} isPowerNet nominalTraceWidth="0.6mm" />
      </Fragment>
    ))}
    <net name="GND" isGroundNet nominalTraceWidth="0.5mm" />
    <net name="V3V3" isPowerNet nominalTraceWidth="0.3mm" />
    {/* solid GND on inner1; each domain adds its own inner2 + bottom pours */}
    <copperpour layer="inner1" connectsTo="net.GND" />
    <AsicStack />

    {stitchPoints.map(([x, y]) => (
      <Via
        key={`gs${x},${y}`}
        pcbX={x}
        pcbY={y}
        holeDiameter="0.3mm"
        outerDiameter="0.6mm"
        connectsTo="net.GND"
      />
    ))}
    {MOUNT_HOLES.map(([x, y]) => (
      <Hole key={`mh${x},${y}`} pcbX={x} pcbY={y} diameter="3.2mm" />
    ))}

    {/* ---------- 12V input ---------- */}
    <chip
      name="CN_PWR"
      footprint="pinrow2_p5.08mm_id1.5mm_od2.8mm"
      pinLabels={{ pin1: "VIN", pin2: "GND" }}
      pcbX={-62.4}
      pcbY={-32.5}
      connections={{ VIN: "net.V12_IN", GND: "net.GND" }}
    />
    {/* input current: 2 mOhm shunt -> INA219 (I2C 0x41) */}
    <resistor
      name="R_SHUNT"
      resistance="0.002"
      footprint="2512"
      pcbX={-51}
      pcbY={-27}
      connections={{ pin1: "net.V12_IN", pin2: "net.V12" }}
    />
    <chip
      name="U_INA"
      manufacturerPartNumber="INA219AIDR"
      footprint="soic8"
      pinLabels={{
        pin1: "A1",
        pin2: "A0",
        pin3: "SDA",
        pin4: "SCL",
        pin5: "VS",
        pin6: "GND",
        pin7: "IN_N",
        pin8: "IN_P",
      }}
      pcbX={-57}
      pcbY={-17}
      connections={{
        IN_P: "net.V12_IN",
        IN_N: "net.V12",
        A0: "net.V3V3",
        A1: "net.GND",
        SDA: "net.SDA",
        SCL: "net.SCL",
        VS: "net.V3V3",
        GND: "net.GND",
      }}
    />
    <capacitor
      name="C_INA"
      capacitance="100nF"
      footprint="0402"
      pcbX={-50}
      pcbY={-17}
      connections={{ pin1: "net.V3V3", pin2: "net.GND" }}
    />
    {/* thin 12V branch for the per-domain IO LDOs (a few mA each) */}
    <resistor
      name="R_V12F"
      resistance="1"
      footprint="0603"
      pcbX={-44}
      pcbY={-40}
      connections={{ pin1: "net.V12", pin2: "net.V12F" }}
    />
    <capacitor
      name="C_IN1"
      capacitance="22uF"
      footprint="1206"
      pcbX={-49.4}
      pcbY={-36.4}
      connections={{ pin1: "net.V12", pin2: "net.GND" }}
    />

    {/* ---------- string buck: 12V -> VSTRING (3.2V) ---------- */}
    <chip
      name="U_BUCK"
      manufacturerPartNumber="TPS54560-class"
      footprint="soic8"
      pinLabels={{
        pin1: "BOOT",
        pin2: "VIN",
        pin3: "EN",
        pin4: "RT",
        pin5: "FB",
        pin6: "COMP",
        pin7: "GND",
        pin8: "SW",
      }}
      pcbX={-36.4}
      pcbY={-28.6}
      connections={{
        VIN: "net.V12",
        EN: "net.VCORE_EN",
        GND: "net.GND",
        SW: "net.SW",
        FB: "net.FB",
      }}
    />
    <capacitor
      name="C_BOOT"
      capacitance="100nF"
      footprint="0402"
      pcbX={-36.4}
      pcbY={-20.8}
      connections={{ pin1: ".U_BUCK > .BOOT", pin2: "net.SW" }}
    />
    <resistor
      name="R_RT"
      resistance="100k"
      footprint="0402"
      pcbX={-44.2}
      pcbY={-20.8}
      connections={{ pin1: ".U_BUCK > .RT", pin2: "net.GND" }}
    />
    <resistor
      name="R_COMP"
      resistance="10k"
      footprint="0402"
      pcbX={-28.6}
      pcbY={-20.8}
      connections={{ pin1: ".U_BUCK > .COMP", pin2: "net.COMP_RC" }}
    />
    <capacitor
      name="C_COMP"
      capacitance="4.7nF"
      footprint="0402"
      pcbX={-28.6}
      pcbY={-16.9}
      connections={{ pin1: "net.COMP_RC", pin2: "net.GND" }}
    />
    <inductor
      name="L1"
      inductance="1.5uH"
      footprint="1210"
      pcbX={-20.8}
      pcbY={-31.2}
      connections={{ pin1: "net.SW", pin2: "net.VSTRING" }}
    />
    {/* FB divider: VSTRING = 0.6V * (1 + 43.2k/10k) ~= 3.19V */}
    <resistor
      name="R_FB1"
      resistance="43.2k"
      footprint="0402"
      pcbX={-13}
      pcbY={-23.4}
      connections={{ pin1: "net.VSTRING", pin2: "net.FB" }}
    />
    <resistor
      name="R_FB2"
      resistance="10k"
      footprint="0402"
      pcbX={-13}
      pcbY={-19.5}
      connections={{ pin1: "net.FB", pin2: "net.GND" }}
    />
    <capacitor
      name="C_OUT1"
      capacitance="100uF"
      footprint="1210"
      pcbX={-10.4}
      pcbY={-33.8}
      connections={{ pin1: "net.VSTRING", pin2: "net.GND" }}
    />
    <capacitor
      name="C_OUT2"
      capacitance="100uF"
      footprint="1210"
      pcbX={-2.6}
      pcbY={-33.8}
      connections={{ pin1: "net.VSTRING", pin2: "net.GND" }}
    />


    {/* ---------- VSTRING power-good: trips below ~2.91V ---------- */}
    <chip
      name="U_PG"
      manufacturerPartNumber="TPS3808G01DBV"
      footprint="sot23_6"
      pinLabels={{
        pin1: "RESET",
        pin2: "GND",
        pin3: "MR",
        pin4: "CT",
        pin5: "SENSE",
        pin6: "VDD",
      }}
      pcbX={26}
      pcbY={-36}
      connections={{
        RESET: "net.PGOOD",
        GND: "net.GND",
        MR: "net.V3V3",
        SENSE: "net.PG_SENSE",
        VDD: "net.V3V3",
      }}
    />
    {/* 0.405V * (1 + 61.9k/10k) = 2.91V, 91% of VSTRING */}
    <resistor
      name="R_PG1"
      resistance="61.9k"
      footprint="0402"
      pcbX={20}
      pcbY={-40}
      connections={{ pin1: "net.VSTRING", pin2: "net.PG_SENSE" }}
    />
    <resistor
      name="R_PG2"
      resistance="10k"
      footprint="0402"
      pcbX={26}
      pcbY={-41}
      connections={{ pin1: "net.PG_SENSE", pin2: "net.GND" }}
    />
    <resistor
      name="R_PGOOD"
      resistance="10k"
      footprint="0402"
      pcbX={32}
      pcbY={-40}
      connections={{ pin1: "net.PGOOD", pin2: "net.V3V3" }}
    />


    {/* ---------- 3.3V <-> 1.8V level shifter for the chain + over-temp ---------- */}
    <chip
      name="U_LS"
      manufacturerPartNumber="TXS0108EPWR"
      footprint="tssop20"
      pinLabels={{
        pin1: "A1",
        pin2: "VCCA",
        pin3: "A2",
        pin4: "A3",
        pin5: "A4",
        pin6: "A5",
        pin7: "A6",
        pin8: "A7",
        pin9: "A8",
        pin10: "OE",
        pin11: "GND",
        pin12: "B8",
        pin13: "B7",
        pin14: "B6",
        pin15: "B5",
        pin16: "B4",
        pin17: "B3",
        pin18: "B2",
        pin19: "VCCB",
        pin20: "B1",
      }}
      pcbX={39}
      pcbY={-26}
      connections={{
        VCCA: "net.VDDIO0",
        VCCB: "net.V3V3",
        GND: "net.GND",
        OE: "net.V3V3",
        A1: "net.CI_1V8",
        B1: "net.TX",
        A2: "net.RO_1V8",
        B2: "net.RX",
        A3: "net.RST_1V8",
        B3: "net.RST",
        A4: "net.BO_1V8",
        B4: "net.BUSY",
        A5: "net.OT_1V8",
        B5: "net.OT_N",
      }}
    />
    <capacitor
      name="C_LS1"
      capacitance="100nF"
      footprint="0402"
      pcbX={32.5}
      pcbY={-19.5}
      connections={{ pin1: "net.VDDIO0", pin2: "net.GND" }}
    />
    <capacitor
      name="C_LS2"
      capacitance="100nF"
      footprint="0402"
      pcbX={45.5}
      pcbY={-19.5}
      connections={{ pin1: "net.V3V3", pin2: "net.GND" }}
    />

    {/* ---------- board temperature sensor (I2C) ---------- */}
    <chip
      name="U_TMP"
      manufacturerPartNumber="TMP75"
      footprint="soic8"
      pinLabels={{
        pin1: "SDA",
        pin2: "SCL",
        pin3: "ALERT",
        pin4: "GND",
        pin5: "A2",
        pin6: "A1",
        pin7: "A0",
        pin8: "VS",
      }}
      pcbX={-55}
      pcbY={41}
      connections={{
        SDA: "net.SDA",
        SCL: "net.SCL",
        GND: "net.GND",
        ALERT: "net.ALERT",
        A0: "net.GND",
        A1: "net.GND",
        A2: "net.GND",
        VS: "net.V3V3",
      }}
    />
    <capacitor
      name="C_TMP"
      capacitance="100nF"
      footprint="0402"
      pcbX={-48.5}
      pcbY={41}
      connections={{ pin1: "net.V3V3", pin2: "net.GND" }}
    />

    {/* ---------- board ID / calibration EEPROM (I2C 0x50) ---------- */}
    <chip
      name="U_EE"
      manufacturerPartNumber="AT24C02D-SSHM"
      footprint="soic8"
      pinLabels={{
        pin1: "A0",
        pin2: "A1",
        pin3: "A2",
        pin4: "GND",
        pin5: "SDA",
        pin6: "SCL",
        pin7: "WP",
        pin8: "VCC",
      }}
      pcbX={8}
      pcbY={-40}
      connections={{
        A0: "net.GND",
        A1: "net.GND",
        A2: "net.GND",
        GND: "net.GND",
        SDA: "net.SDA",
        SCL: "net.SCL",
        WP: "net.GND",
        VCC: "net.V3V3",
      }}
    />
    <capacitor
      name="C_EE"
      capacitance="100nF"
      footprint="0402"
      pcbX={14}
      pcbY={-44}
      connections={{ pin1: "net.V3V3", pin2: "net.GND" }}
    />

    {/* ---------- controller connector ---------- */}
    <chip
      name="CN_CTRL"
      footprint="pinrow16_rows2"
      pinLabels={{
        pin1: "V3V3_A",
        pin2: "V3V3_B",
        pin3: "GND_A",
        pin4: "GND_B",
        pin5: "TX",
        pin6: "RX",
        pin7: "RST",
        pin8: "BUSY",
        pin9: "SDA",
        pin10: "SCL",
        pin11: "PGOOD",
        pin12: "VCORE_EN",
        pin13: "OT_N",
        pin14: "ALERT",
        pin15: "GND_C",
        pin16: "GND_D",
      }}
      pcbX={78}
      pcbY={0}
      pcbRotation={90}
      connections={{
        V3V3_A: "net.V3V3",
        V3V3_B: "net.V3V3",
        GND_A: "net.GND",
        GND_B: "net.GND",
        TX: "net.TX",
        RX: "net.RX",
        RST: "net.RST",
        BUSY: "net.BUSY",
        SDA: "net.SDA",
        SCL: "net.SCL",
        PGOOD: "net.PGOOD",
        VCORE_EN: "net.VCORE_EN",
        OT_N: "net.OT_N",
        ALERT: "net.ALERT",
        GND_C: "net.GND",
        GND_D: "net.GND",
      }}
    />
    <resistor
      name="R_SDA"
      resistance="4.7k"
      footprint="0402"
      pcbX={69}
      pcbY={18.2}
      connections={{ pin1: "net.SDA", pin2: "net.V3V3" }}
    />
    <resistor
      name="R_SCL"
      resistance="4.7k"
      footprint="0402"
      pcbX={69}
      pcbY={22.1}
      connections={{ pin1: "net.SCL", pin2: "net.V3V3" }}
    />
    <resistor
      name="R_EN"
      resistance="100k"
      footprint="0402"
      pcbX={69}
      pcbY={-10.4}
      connections={{ pin1: "net.VCORE_EN", pin2: "net.GND" }}
    />
    <resistor
      name="R_ALERT"
      resistance="10k"
      footprint="0402"
      pcbX={69}
      pcbY={26}
      connections={{ pin1: "net.ALERT", pin2: "net.V3V3" }}
    />

    {/* ---------- ESD on every controller-facing signal ---------- */}
    <chip
      name="D_ESD1"
      manufacturerPartNumber="SRV05-4"
      footprint="sot23_6"
      pinLabels={{
        pin1: "IO1",
        pin2: "GND",
        pin3: "IO2",
        pin4: "IO3",
        pin5: "VP",
        pin6: "IO4",
      }}
      pcbX={65}
      pcbY={-3}
      connections={{
        IO1: "net.TX",
        IO2: "net.RX",
        IO3: "net.RST",
        IO4: "net.BUSY",
        GND: "net.GND",
        VP: "net.V3V3",
      }}
    />
    <chip
      name="D_ESD2"
      manufacturerPartNumber="SRV05-4"
      footprint="sot23_6"
      pinLabels={{
        pin1: "IO1",
        pin2: "GND",
        pin3: "IO2",
        pin4: "IO3",
        pin5: "VP",
        pin6: "IO4",
      }}
      pcbX={65}
      pcbY={6}
      connections={{
        IO1: "net.SDA",
        IO2: "net.SCL",
        IO3: "net.OT_N",
        IO4: "net.ALERT",
        GND: "net.GND",
        VP: "net.V3V3",
      }}
    />
  </board>
)
