// SPDX-License-Identifier: CERN-OHL-W-2.0
// Digital core chain for the live host simulator. CI/RO are actual UART pins;
// the C++ bridge serializes bytes into bits and samples replies from the RTL.
// This wrapper does not model PLL, package, board power or analog temperature.
module zeq_sim_top #(
    parameter integer N = 48, K = 5, DIV = 8, CHIPS = 1,
    parameter integer BB = (N == 200 ? 12 : 4),
    parameter integer PB = (N == 200 ? 4 : 2),
    parameter integer SB = (N == 200 ? 10 : 8),
    parameter integer SLOTS = (N == 200 ? 640 : 256),
    parameter integer BUCKET0_SLOTS = (N == 200 ? 768 : 256)
) (
    input wire clk,
    input wire rst_n,
    input wire host_tx,
    output wire host_rx,
    output wire busy_n,
    input wire [7:0] temperature
);
    wire [CHIPS:0] command, reply, busy, reset;
    assign command[0] = host_tx;
    assign reset[0] = rst_n;
    assign reply[CHIPS] = 1'b1;
    assign busy[CHIPS] = 1'b1;
    assign host_rx = reply[0];
    assign busy_n = busy[0];
    genvar chip;
    generate for (chip = 0; chip < CHIPS; chip = chip + 1) begin : g_chip
        zeq200_core #(
            .N(N), .K(K), .LANES(1), .EXT_MEM(0), .DIV(DIV),
            .ARCH(1), .SHARE_FILTER(1), .BOOT_BIST(0),
            .PAR_BB(BB), .PAR_PB(PB), .PAR_HPB(PB), .PAR_SB(SB),
            .PAR_SLOTS(SLOTS), .PAR_BUCKET0_SLOTS(BUCKET0_SLOTS),
            .PAR_PACKED_TABLES(1), .PAR_SPLIT_KEYS(1),
            .PAR_COMPACT_VALUES(1), .PAR_STAGED_NETWORK(0)
        ) core (
            .clk(clk), .rst_n(reset[chip]), .rsto_n(reset[chip+1]),
            .addr_strap(chip[1:0]),
            .ci(command[chip]), .co(command[chip+1]),
            .ri(reply[chip+1]), .ro(reply[chip]),
            .bi(busy[chip+1]), .bo(busy[chip]),
            .tsense(temperature), .temp_pull(),
            .val_req_valid(), .val_req_ready(1'b0), .val_req_we(),
            .val_req_addr(), .val_req_wdata(), .val_rsp_valid(1'b0),
            .val_rsp_rdata({N{1'b0}}),
            .ptr_req_valid(), .ptr_req_ready(1'b0), .ptr_req_we(),
            .ptr_req_addr(), .ptr_req_wdata(), .ptr_rsp_valid(1'b0),
            .ptr_rsp_rdata({(2*(N/(K+1)+2)){1'b0}}),
            .ord_req_valid(), .ord_req_ready(1'b0), .ord_req_we(),
            .ord_req_addr(), .ord_req_wdata(), .ord_rsp_valid(1'b0),
            .ord_rsp_rdata({(N/(K+1)+2){1'b0}})
        );
    end endgenerate
endmodule
