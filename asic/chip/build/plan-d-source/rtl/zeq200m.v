// ZEQ-200M: the mainnet (200,9) compute die.
//
// Same core as the test chip, but every lane's big tables are served by
// external DRAM (~0.4 GiB per lane at 200,9: two value banks of CAP x 200
// bits, 8 pointer levels of CAP x 44 bits, the order table). The 2.9 MB
// collision histogram stays on die inside each solver.
// Each lane exposes its four table ports; on silicon they connect to a
// DRAM controller + PHY (LPDDR/HBM IP from an external provider), which
// no open PDK provides, so the ports are this block's boundary.
`default_nettype none

module zeq200m #(
    parameter integer N     = 200,
    parameter integer K     = 9,
    parameter integer LANES = 2,
    parameter integer DIV   = 16,
    // derived (do not override)
    parameter integer CB    = N / (K + 1),
    parameter integer RW    = CB + 2,
    parameter integer CW    = CB + 3,
    parameter integer CAP   = 1 << (CB + 2),
    parameter integer VVA   = CB + 3,
    parameter integer PVA   = $clog2((K - 1) * CAP)
) (
    input  wire       clk,         // from the PLL macro
    input  wire       rst_n,
    output wire       rsto_n,
    input  wire [1:0] addr_strap,
    input  wire       ci,
    output wire       co,
    input  wire       ri,
    output wire       ro,
    input  wire       bi,
    output wire       bo,
    input  wire [7:0] tsense,      // from the thermal-sensor macro
    output wire       temp_pull,
    output wire [LANES-1:0]      val_req_valid,
    input  wire [LANES-1:0]      val_req_ready,
    output wire [LANES-1:0]      val_req_we,
    output wire [LANES*VVA-1:0]  val_req_addr,
    output wire [LANES*N-1:0]    val_req_wdata,
    input  wire [LANES-1:0]      val_rsp_valid,
    input  wire [LANES*N-1:0]    val_rsp_rdata,
    output wire [LANES-1:0]      ptr_req_valid,
    input  wire [LANES-1:0]      ptr_req_ready,
    output wire [LANES-1:0]      ptr_req_we,
    output wire [LANES*PVA-1:0]  ptr_req_addr,
    output wire [LANES*2*RW-1:0] ptr_req_wdata,
    input  wire [LANES-1:0]      ptr_rsp_valid,
    input  wire [LANES*2*RW-1:0] ptr_rsp_rdata,
    output wire [LANES-1:0]      ord_req_valid,
    input  wire [LANES-1:0]      ord_req_ready,
    output wire [LANES-1:0]      ord_req_we,
    output wire [LANES*RW-1:0]   ord_req_addr,
    output wire [LANES*RW-1:0]   ord_req_wdata,
    input  wire [LANES-1:0]      ord_rsp_valid,
    input  wire [LANES*RW-1:0]   ord_rsp_rdata
);
    zeq200_core #(.N(N), .K(K), .LANES(LANES), .EXT_MEM(1), .DIV(DIV)) u_core (
        .clk(clk), .rst_n(rst_n), .rsto_n(rsto_n), .addr_strap(addr_strap),
        .ci(ci), .co(co), .ri(ri), .ro(ro), .bi(bi), .bo(bo),
        .tsense(tsense), .temp_pull(temp_pull),
        .val_req_valid(val_req_valid), .val_req_ready(val_req_ready), .val_req_we(val_req_we),
        .val_req_addr(val_req_addr), .val_req_wdata(val_req_wdata),
        .val_rsp_valid(val_rsp_valid), .val_rsp_rdata(val_rsp_rdata),
        .ptr_req_valid(ptr_req_valid), .ptr_req_ready(ptr_req_ready), .ptr_req_we(ptr_req_we),
        .ptr_req_addr(ptr_req_addr), .ptr_req_wdata(ptr_req_wdata),
        .ptr_rsp_valid(ptr_rsp_valid), .ptr_rsp_rdata(ptr_rsp_rdata),
        .ord_req_valid(ord_req_valid), .ord_req_ready(ord_req_ready), .ord_req_we(ord_req_we),
        .ord_req_addr(ord_req_addr), .ord_req_wdata(ord_req_wdata),
        .ord_rsp_valid(ord_rsp_valid), .ord_rsp_rdata(ord_rsp_rdata));
endmodule

`default_nettype wire
