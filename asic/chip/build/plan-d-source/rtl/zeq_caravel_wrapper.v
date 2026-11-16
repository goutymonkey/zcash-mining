// Shuttle-harness wrapper for the ZEQ-200 test chip (Caravel-style
// user_project_wrapper port list: 38 GPIOs, logic analyzer, user clock).
//
// GPIO map (io_oeb = 1: input, 0: output)
//   io[8]   RSTN   in      io[9]   RSTO   out
//   io[10]  CI     in      io[11]  CO     out
//   io[12]  RI     in      io[13]  RO     out
//   io[14]  BI     in      io[15]  BO     out
//   io[16]  ADDR0  in      io[17]  ADDR1  in
//   io[18]  TEMP   open drain: driven low when over temperature, else high-Z
//   io[19], io[20]  reserved outputs (driven low); BIST status is in PONG
// Clock: user_clock2 (pad or PLL). The management core supplies the
// thermal-sensor code on la_data_in[7:0] (no analog sensor on this shuttle)
// and can read the chain pins back on la_data_out[7:0].
`default_nettype none

module zeq_caravel_wrapper #(
    parameter integer IO = 38
) (
`ifdef USE_POWER_PINS
    inout  wire          vccd1,
    inout  wire          vssd1,
`endif
    input  wire          wb_clk_i,
    input  wire          wb_rst_i,
    // Wishbone slave: not used (the chain protocol is the only control
    // path); acknowledges nothing and reads as zero
    input  wire          wbs_stb_i,
    input  wire          wbs_cyc_i,
    input  wire          wbs_we_i,
    input  wire [3:0]    wbs_sel_i,
    input  wire [31:0]   wbs_dat_i,
    input  wire [31:0]   wbs_adr_i,
    output wire          wbs_ack_o,
    output wire [31:0]   wbs_dat_o,
    input  wire          user_clock2,
    input  wire [127:0]  la_data_in,
    output wire [127:0]  la_data_out,
    input  wire [127:0]  la_oenb,
    // io[8] is the asynchronous reset, the other bits synchronous inputs
    /* verilator lint_off SYNCASYNCNET */
    input  wire [IO-1:0] io_in,
    /* verilator lint_on SYNCASYNCNET */
    output wire [IO-1:0] io_out,
    output wire [IO-1:0] io_oeb,
    output wire [2:0]    user_irq
);
    wire rsto_n, co, ro, bo, temp_pull;

    zeq200_tc u_tc (
        .clk(user_clock2), .rst_n(io_in[8]), .rsto_n(rsto_n),
        .addr_strap({io_in[17], io_in[16]}),
        .ci(io_in[10]), .co(co), .ri(io_in[12]), .ro(ro),
        .bi(io_in[14]), .bo(bo), .tsense(la_data_in[7:0]), .temp_pull(temp_pull));

    // outputs
    assign io_out[9]  = rsto_n;
    assign io_out[11] = co;
    assign io_out[13] = ro;
    assign io_out[15] = bo;
    assign io_out[18] = 1'b0;          // open drain: only ever drives low
    assign io_out[19] = 1'b0;
    assign io_out[20] = 1'b0;

    genvar i;
    generate
        for (i = 0; i < IO; i = i + 1) begin : g_io
            if (i == 9 || i == 11 || i == 13 || i == 15 || i == 19 || i == 20) begin : g_out
                assign io_oeb[i] = 1'b0;
            end else if (i == 18) begin : g_od
                assign io_oeb[i] = ~temp_pull;          // enable only to pull low
            end else begin : g_in
                assign io_oeb[i] = 1'b1;
                if (i != 18) begin : g_z
                    assign io_out[i] = 1'b0;
                end
            end
        end
    endgenerate

    assign la_data_out = {120'd0, temp_pull, bo, ro, co, rsto_n, io_in[14], io_in[12], io_in[10]};
    assign user_irq    = {2'b00, temp_pull};    // over-temperature interrupt to the SoC

    assign wbs_ack_o = 1'b0;
    assign wbs_dat_o = 32'd0;

    wire unused = &{1'b0, wb_clk_i, wb_rst_i, la_oenb, la_data_in[127:8],
                    wbs_stb_i, wbs_cyc_i, wbs_we_i, wbs_sel_i, wbs_dat_i, wbs_adr_i};
endmodule

`default_nettype wire
