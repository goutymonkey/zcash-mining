// ZEQ-200 test chip core for tapeout on an open PDK (SKY130): the ZEQ-200X
// bucket-parallel architecture at test scale - one lane, (48,5), 2 engines
// with their own SRAM banks, 8 buckets x 128 slots, every table on die with
// March C- BIST, Blake2b split into quarter steps (one 64-bit add per
// cycle, see zeq_blake2b). Share filtering runs on the host to reduce area. This is the hardened block;
// the pad ring / harness supplies the clock (PLL or pad), the thermal
// sensor code, and turns temp_pull into the open-drain TEMP pad.
`default_nettype none

module zeq200_tc (
    input  wire       clk,
    input  wire       rst_n,
    output wire       rsto_n,
    input  wire [1:0] addr_strap,
    input  wire       ci,
    output wire       co,
    input  wire       ri,
    output wire       ro,
    input  wire       bi,
    output wire       bo,
    input  wire [7:0] tsense,
    output wire       temp_pull
);
    localparam integer N = 48, K = 5, LANES = 1;
    localparam integer CB = N / (K + 1), RW = CB + 2, CW = CB + 3;

    zeq200_core #(.N(N), .K(K), .LANES(LANES), .EXT_MEM(0), .DIV(16), .HASH_SPLIT(4),
                  .SHARE_FILTER(0), .ARCH(1), .PAR_BB(3), .PAR_PB(1), .PAR_SB(7), .PAR_HPB(0)) u_core (
        .clk(clk), .rst_n(rst_n), .rsto_n(rsto_n), .addr_strap(addr_strap),
        .ci(ci), .co(co), .ri(ri), .ro(ro), .bi(bi), .bo(bo),
        .tsense(tsense), .temp_pull(temp_pull),
        .val_req_valid(), .val_req_ready(1'b0), .val_req_we(), .val_req_addr(),
        .val_req_wdata(), .val_rsp_valid(1'b0), .val_rsp_rdata({N{1'b0}}),
        .ptr_req_valid(), .ptr_req_ready(1'b0), .ptr_req_we(), .ptr_req_addr(),
        .ptr_req_wdata(), .ptr_rsp_valid(1'b0), .ptr_rsp_rdata({(2*RW){1'b0}}),
        .ord_req_valid(), .ord_req_ready(1'b0), .ord_req_we(), .ord_req_addr(),
        .ord_req_wdata(), .ord_rsp_valid(1'b0), .ord_rsp_rdata({RW{1'b0}}));
endmodule

`default_nettype wire
