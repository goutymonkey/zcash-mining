// Byte FIFO with a synchronous-read array (maps onto an SRAM macro) and a
// one-entry output register, so the head byte is visible without an
// asynchronous read ("first word fall through").
`default_nettype none

module zeq_fifo #(
    parameter integer AW = 9,
    parameter integer DW = 8
) (
    input  wire          clk,
    input  wire          rst,
    input  wire          push,
    input  wire [DW-1:0] din,
    output wire          full,
    input  wire          pop,     // consume dout (only when !empty)
    output wire          empty,
    output reg  [DW-1:0] dout,
    output wire [AW:0]   level     // bytes held (array + output register)
);
    reg [AW:0]   wp, rp;       // array pointers
    reg          out_valid;    // dout holds a byte
    reg          rd_pend;      // array read issued, data lands in rdata
    wire [DW-1:0] rdata;

    wire arr_empty = (wp == rp);
    assign level = (wp - rp) + {{AW{1'b0}}, out_valid} + {{AW{1'b0}}, rd_pend};
    assign full  = (wp[AW] != rp[AW]) && (wp[AW-1:0] == rp[AW-1:0]);
    assign empty = ~out_valid;

    // fetch when the output slot is (or is about to become) free
    wire slot_free = ~out_valid | pop;
    wire fetch     = ~arr_empty & ~rd_pend & slot_free;

    // the array: 1 write + 1 registered read port (an SRAM macro on SKY130;
    // as flip-flops its 2^AW:1 read mux dominated local routing)
    wire unused_bd, unused_bf;
    zeq_ram #(.AW(AW), .DW(DW), .FORCE_MACRO(1)) u_ram (
        .clk(clk), .we(push && !full), .waddr(wp[AW-1:0]), .wdata(din),
        .re(fetch), .raddr(rp[AW-1:0]), .rdata(rdata),
        .rst(rst), .bist_start(1'b0), .bist_done(unused_bd), .bist_fail(unused_bf));

    always @(posedge clk) begin
        if (rst) begin
            wp <= 0;
            rp <= 0;
            out_valid <= 1'b0;
            rd_pend <= 1'b0;
        end else begin
            if (push && !full) wp <= wp + 1'b1;
            if (fetch) rp <= rp + 1'b1;
            rd_pend <= fetch;
            if (rd_pend) begin
                dout <= rdata;
                out_valid <= 1'b1;
            end else if (pop) begin
                out_valid <= 1'b0;
            end
        end
    end
`ifdef FORMAL
    // proved: level never exceeds the array plus the output stages
    always @* if (!rst) assert (level <= (1 << AW) + 1);
`elsif SYNTHESIS
`else
    // simulation check: the link's flow control must make this impossible
    always @(posedge clk)
        if (!rst && push && full) $fatal(1, "zeq_fifo overflow in %m");
`endif
endmodule

`default_nettype wire
