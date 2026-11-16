// Gate-level variant of the ZEQ-200 pad ring for simulation: the same
// pins and analog stubs as rtl/zeq200.v, around the Yosys-synthesized core
// netlist (build/gl/zeq200_core_gl.v, test-chip parameters). Parameters are
// accepted for drop-in use but the netlist is fixed at N=48 K=5 LANES=1
// DIV=8 HASH_SPLIT=4.
`default_nettype none

module zeq_pll (input wire clk_ref, output wire clk_core);
    assign clk_core = clk_ref;
endmodule

module zeq_tsense (output wire [7:0] code);
    reg [7:0] code_r = 8'd60;  // testbenches poke this to model heating
    assign code = code_r;
endmodule

module zeq200_gl #(
    parameter integer N     = 48,
    parameter integer K     = 5,
    parameter integer LANES = 1,
    parameter integer DIV   = 16,
    parameter integer HASH_SPLIT = 1,
    parameter integer SHARE_FILTER = 1,
    parameter integer ARCH  = 0,         // netlist config is fixed (accepted, unused)
    parameter integer PAR_BB = 4,
    parameter integer PAR_PB = 2,
    parameter integer PAR_SB = 8,
    parameter integer PAR_HPB = PAR_PB     // (fixed in the netlist; interface only)
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
    zeq200_core_gl u_core (
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
