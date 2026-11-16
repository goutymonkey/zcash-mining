// ZEQ-200 pad ring: the pins match lib/ZeqAsic.tsx on the hashboard.
//
// Two analog blocks are hard macros in silicon and behavioral stubs here:
//   zeq_pll     VDDPLL-powered clock multiplier (modelled as a pass-through)
//   zeq_tsense  on-die thermal diode + ADC (code settable from a testbench)
// Power pins (VDD1-6, VDDIO1-2, VDDPLL, VSS, EPAD) and the NC pin have no
// logic and are left to the physical design.
`default_nettype none

module zeq_pll (input wire clk_ref, output wire clk_core);
    assign clk_core = clk_ref;
endmodule

module zeq_tsense (output wire [7:0] code);
    reg [7:0] code_r = 8'd60;  // testbenches poke this to model heating
    assign code = code_r;
endmodule

module zeq200 #(
    parameter integer N     = 48,
    parameter integer K     = 5,
    parameter integer LANES = 1,
    parameter integer DIV   = 16,
    parameter integer HASH_SPLIT = 1,
    parameter integer SHARE_FILTER = 1,
    parameter integer ARCH  = 0,
    parameter integer PAR_BB = 4,
    parameter integer PAR_PB = 2,
    parameter integer PAR_SB = 8,
    parameter integer PAR_HPB = PAR_PB
) (
    input  wire CLKI,
    output wire CLKO,
    input  wire CI,
    output wire CO,
    input  wire RI,
    output wire RO,
    input  wire BI,
    output wire BO,
    input  wire RSTN,
    output wire RSTO,
    input  wire ADDR0,
    input  wire ADDR1,
    inout  wire TEMP    // open-drain, active low
);
    wire clk, temp_pull;
    wire [7:0] tcode;

    zeq_pll    u_pll (.clk_ref(CLKI), .clk_core(clk));
    zeq_tsense u_tsense (.code(tcode));

    assign CLKO = CLKI;
    assign TEMP = temp_pull ? 1'b0 : 1'bz;

    // tables on die; the external table ports are unused and tied off
    zeq200_core #(.N(N), .K(K), .LANES(LANES), .EXT_MEM(0), .DIV(DIV), .HASH_SPLIT(HASH_SPLIT),
                  .SHARE_FILTER(SHARE_FILTER), .ARCH(ARCH), .PAR_BB(PAR_BB), .PAR_PB(PAR_PB), .PAR_SB(PAR_SB), .PAR_HPB(PAR_HPB)) u_core (
        .clk(clk), .rst_n(RSTN), .rsto_n(RSTO), .addr_strap({ADDR1, ADDR0}),
        .ci(CI), .co(CO), .ri(RI), .ro(RO), .bi(BI), .bo(BO),
        .tsense(tcode), .temp_pull(temp_pull),
        .val_req_valid(), .val_req_ready({LANES{1'b0}}), .val_req_we(), .val_req_addr(),
        .val_req_wdata(), .val_rsp_valid({LANES{1'b0}}), .val_rsp_rdata({(LANES*N){1'b0}}),
        .ptr_req_valid(), .ptr_req_ready({LANES{1'b0}}), .ptr_req_we(), .ptr_req_addr(),
        .ptr_req_wdata(), .ptr_rsp_valid({LANES{1'b0}}), .ptr_rsp_rdata({(LANES*2*(N/(K+1)+2)){1'b0}}),
        .ord_req_valid(), .ord_req_ready({LANES{1'b0}}), .ord_req_we(), .ord_req_addr(),
        .ord_req_wdata(), .ord_rsp_valid({LANES{1'b0}}), .ord_rsp_rdata({(LANES*(N/(K+1)+2)){1'b0}}));
endmodule

`default_nettype wire
