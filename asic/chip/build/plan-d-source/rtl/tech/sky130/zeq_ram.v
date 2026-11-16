// SKY130 implementation of zeq_ram: 1W1R tiled from OpenRAM
// sky130_sram_2kbyte_1rw1r_32x512_8 macros (port 0 writes, port 1 reads);
// memories of 4 kbit or less are flip-flops unless FORCE_MACRO is set.
`default_nettype none

module zeq_ram #(
    parameter integer AW = 8,
    parameter integer DW = 8,
    parameter integer DEPTH = 1 << AW,
    parameter integer FORCE_MACRO = 0     // SKY130: SRAM macro even when <= 4 kbit
) (
    input  wire          clk,
    input  wire          we,
    input  wire [AW-1:0] waddr,
    input  wire [DW-1:0] wdata,
    input  wire          re,
    input  wire [AW-1:0] raddr,
    output wire [DW-1:0] rdata,
    input  wire          rst,
    input  wire          bist_start,
    output wire          bist_done,
    output wire          bist_fail
);
    // March C- self-test in front of the macros (same as the generic model)
    wire          b_act, b_pass, b_we, b_re;
    wire [AW-1:0] b_wa, b_ra;
    wire [DW-1:0] b_wd;
    zeq_mbist #(.AW(AW), .DW(DW), .DEPTH(DEPTH)) u_bist (
        .clk(clk), .rst(rst), .start(bist_start), .active(b_act), .done(bist_done),
        .pass(b_pass), .we(b_we), .waddr(b_wa), .wdata(b_wd), .re(b_re), .raddr(b_ra),
        .rdata(rdata));
    assign bist_fail = bist_done && !b_pass;
    wire          m_we = b_act ? b_we : we;
    wire [AW-1:0] m_wa = b_act ? b_wa : waddr;
    wire [DW-1:0] m_wd = b_act ? b_wd : wdata;
    wire          m_re = b_act ? b_re : re;
    wire [AW-1:0] m_ra = b_act ? b_ra : raddr;
    generate
        if (DEPTH * DW <= 4096 && FORCE_MACRO == 0) begin : g_ff
            reg [DW-1:0] mem [0:DEPTH-1];
            reg [DW-1:0] q;
            always @(posedge clk) begin
                if (m_we) mem[m_wa] <= m_wd;
                if (m_re) q <= mem[m_ra];
            end
            assign rdata = q;
        end else begin : g_macro
            localparam integer NW = (DW + 31) / 32;
            localparam integer ND = (DEPTH + 511) / 512;
            localparam integer BW = (ND > 1) ? $clog2(ND) : 1;
            wire [BW-1:0] wbank, rbank;
            if (ND > 1) begin : g_bank
                assign wbank = m_wa[AW-1:9];
                assign rbank = m_ra[AW-1:9];
            end else begin : g_nobank
                assign wbank = 1'b0;
                assign rbank = 1'b0;
            end
            wire [8:0] wa9, ra9;
            if (AW >= 9) begin : g_a9
                assign wa9 = m_wa[8:0];
                assign ra9 = m_ra[8:0];
            end else begin : g_apad
                assign wa9 = {{(9-AW){1'b0}}, m_wa};
                assign ra9 = {{(9-AW){1'b0}}, m_ra};
            end
            reg [BW-1:0] rbank_q;
            always @(posedge clk) if (m_re) rbank_q <= rbank;
            wire [NW*32-1:0] wpad = {{(NW*32-DW){1'b0}}, m_wd};
            wire [NW*32-1:0] dout [0:ND-1];
            genvar d, w;
            for (d = 0; d < ND; d = d + 1) begin : g_d
                for (w = 0; w < NW; w = w + 1) begin : g_w
                    wire [31:0] unused_dout0;
                    sky130_sram_2kbyte_1rw1r_32x512_8 u_mem (
                        .clk0(clk), .csb0(~(m_we && wbank == d)), .web0(1'b0), .wmask0(4'hF),
                        .addr0(wa9), .din0(wpad[w*32 +: 32]), .dout0(unused_dout0),
                        .clk1(clk), .csb1(~(m_re && rbank == d)), .addr1(ra9),
                        .dout1(dout[d][w*32 +: 32]));
                end
            end
            assign rdata = dout[rbank_q][DW-1:0];
        end
    endgenerate
endmodule

`default_nettype wire
