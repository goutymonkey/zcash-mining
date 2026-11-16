/**
 * ZEQ-200: a hypothetical Equihash (200,9) mining ASIC.
 *
 * tscircuit designs boards, not silicon, so the die itself is a black box
 * here: this component is the package + pinout a hashboard would be built
 * around. The pinout follows the daisy-chain convention used by commercial
 * mining ASICs: command in/out (CI/CO), response in/out (RI/RO), busy
 * (BI/BO), reset passthrough, and a forwarded reference clock.
 */
// Pins are grouped by side so the chain flows left-to-right across a board:
// upstream-facing pins on the left, downstream-facing on the right, core
// power on the bottom edge and IO power on the top edge. The whole bottom
// edge is VDD and the exposed pad is the main ground, so no two wide power
// nets ever sit on adjacent 0.5mm-pitch pins (in a series stack VDD and VSS
// are both heavy domain rails).
export const zeqPinLabels = {
  // left side (pin 1 at top): from / to the previous chip
  pin1: "CLKI",
  pin2: "CI",
  pin3: "RSTN",
  pin4: "RO",
  pin5: "BO",
  pin6: "TEMP", // open-drain over-temp flag; relayed toward domain 0
  // bottom side: core supply
  pin7: "VDD1",
  pin8: "VDD2",
  pin9: "VDD3",
  pin10: "VDD4",
  pin11: "VDD5",
  pin12: "VDD6",
  // right side (pin 13 at bottom): to / from the next chip
  pin13: "VDDIO1",
  pin14: "BI",
  pin15: "RI",
  pin16: "RSTO",
  pin17: "CO",
  pin18: "CLKO",
  // top side: IO supply, PLL, address straps
  pin19: "VDDIO2",
  pin20: "VDDPLL",
  pin21: "ADDR1",
  pin22: "ADDR0",
  pin23: "VSS",
  pin24: "NC",
  // main ground; "thermalpad" binds this pin to the footprint's exposed pad
  pin25: ["EPAD", "thermalpad"],
} as const

type ZeqPin = Exclude<
  (typeof zeqPinLabels)[keyof typeof zeqPinLabels],
  readonly string[]
> | "EPAD"

export const ZeqAsic = (props: {
  name: string
  pcbX?: number
  pcbY?: number
  schX?: number
  schY?: number
  connections?: Partial<Record<ZeqPin, string>>
}) => (
  <chip
    {...props}
    manufacturerPartNumber="ZEQ-200"
    footprint="qfn24_thermalpad"
    pinLabels={zeqPinLabels}
    schWidth={4}
    schHeight={3.4}
    schPinArrangement={{
      leftSide: {
        direction: "top-to-bottom",
        pins: ["CLKI", "CI", "RSTN", "RO", "BO", "TEMP", "ADDR0", "ADDR1"],
      },
      rightSide: {
        direction: "top-to-bottom",
        pins: ["CLKO", "CO", "RSTO", "RI", "BI", "NC"],
      },
      topSide: {
        direction: "left-to-right",
        pins: [
          "VDD1",
          "VDD2",
          "VDD3",
          "VDD4",
          "VDD5",
          "VDD6",
          "VDDPLL",
          "VDDIO1",
          "VDDIO2",
        ],
      },
      bottomSide: {
        direction: "left-to-right",
        pins: ["VSS", "EPAD"],
      },
    }}
  />
)
