// One-write, one-read RAM with a registered read (the data output only
// changes on a read), plus March C- self-test. Behavioral;
// rtl/tech/sky130/zeq_ram.v is the macro implementation with the same
// ports and timing. A read and a write to the same address in one cycle
// return the old data. While the BIST runs it owns both ports.
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
    wire          b_act, b_pass, b_we, b_re;
    wire [AW-1:0] b_wa, b_ra;
    wire [DW-1:0] b_wd;
    zeq_mbist #(.AW(AW), .DW(DW), .DEPTH(DEPTH)) u_bist (
        .clk(clk), .rst(rst), .start(bist_start), .active(b_act), .done(bist_done),
        .pass(b_pass), .we(b_we), .waddr(b_wa), .wdata(b_wd), .re(b_re), .raddr(b_ra),
        .rdata(rdata));
    assign bist_fail = bist_done && !b_pass;

    reg [DW-1:0] mem [0:DEPTH-1];
    reg [DW-1:0] q;
    wire          m_we = b_act ? b_we : we;
    wire [AW-1:0] m_wa = b_act ? b_wa : waddr;
    wire [DW-1:0] m_wd = b_act ? b_wd : wdata;
    wire          m_re = b_act ? b_re : re;
    wire [AW-1:0] m_ra = b_act ? b_ra : raddr;
    always @(posedge clk) begin
        if (m_we) mem[m_wa] <= m_wd;
        if (m_re) q <= mem[m_ra];
    end
    assign rdata = q;
endmodule

`default_nettype wire
