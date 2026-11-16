// SKY130 implementation of zeq_sram_port (drop-in for rtl/zeq_tables_sram.v
// in physical-design builds): the table is tiled from OpenRAM
// sky130_sram_2kbyte_1rw1r_32x512_8 macros, 32 bits x 512 words each.
// Tables of 4 kbit or less use flip-flops instead.
//
// Timing matches the generic model: always ready, read data on the cycle
// after the request (macro clock-to-q, then a bank mux).
`default_nettype none

module zeq_sram_port #(
    parameter integer AW = 10,
    parameter integer DW = 32,
    parameter integer DEPTH = 1 << AW
) (
    input  wire          clk,
    input  wire          req_valid,
    output wire          req_ready,
    input  wire          req_we,
    input  wire [AW-1:0] req_addr,
    input  wire [DW-1:0] req_wdata,
    output reg           rsp_valid,
    output wire [DW-1:0] rsp_rdata
);
    assign req_ready = 1'b1;
    always @(posedge clk) rsp_valid <= req_valid & ~req_we;

    generate
        if (DEPTH * DW <= 4096) begin : g_ff
            reg [DW-1:0] mem [0:DEPTH-1];
            reg [DW-1:0] q;
            always @(posedge clk)
                if (req_valid) begin
                    if (req_we) mem[req_addr] <= req_wdata;
                    else q <= mem[req_addr];
                end
            assign rsp_rdata = q;
        end else begin : g_macro
            localparam integer NW = (DW + 31) / 32;        // macros across
            localparam integer ND = (DEPTH + 511) / 512;   // banks down
            localparam integer BW = (ND > 1) ? $clog2(ND) : 1;
            wire [8:0]    row  = req_addr[8:0];
            wire [BW-1:0] bank;
            if (ND > 1) begin : g_bank
                assign bank = req_addr[AW-1:9];
            end else begin : g_nobank
                assign bank = 1'b0;
            end
            reg  [BW-1:0]    bank_q;
            always @(posedge clk) if (req_valid) bank_q <= bank;

            wire [NW*32-1:0] wpad = {{(NW*32-DW){1'b0}}, req_wdata};
            wire [NW*32-1:0] dout [0:ND-1];
            genvar d, w;
            for (d = 0; d < ND; d = d + 1) begin : g_d
                for (w = 0; w < NW; w = w + 1) begin : g_w
                    wire [31:0] unused_dout1;
                    sky130_sram_2kbyte_1rw1r_32x512_8 u_mem (
                        .clk0(clk),
                        .csb0(~(req_valid && bank == d)),
                        .web0(~req_we),
                        .wmask0(4'hF),
                        .addr0(row),
                        .din0(wpad[w*32 +: 32]),
                        .dout0(dout[d][w*32 +: 32]),
                        .clk1(clk),
                        .csb1(1'b1),
                        .addr1(9'd0),
                        .dout1(unused_dout1));
                end
            end
            assign rsp_rdata = dout[bank_q][DW-1:0];
        end
    endgenerate
endmodule

`default_nettype wire
