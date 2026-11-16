// Small register FIFO for solver streams: combinational head, count output
// (used for credit accounting against in-flight reads).
`default_nettype none

module zeq_sfifo #(
    parameter integer W = 8,
    parameter integer D = 8        // power of two
) (
    input  wire                 clk,
    input  wire                 clr,
    input  wire                 push,
    input  wire [W-1:0]         din,
    input  wire                 pop,
    output wire [W-1:0]         dout,
    output wire                 empty,
    output reg  [$clog2(D):0]   count
);
    localparam integer AW = $clog2(D);
    reg [W-1:0]  mem [0:D-1];
    reg [AW-1:0] wp, rp;
    assign dout  = mem[rp];
    assign empty = (count == 0);
    always @(posedge clk) begin
        if (clr) begin
            wp <= 0; rp <= 0; count <= 0;
        end else begin
            if (push) begin mem[wp] <= din; wp <= wp + 1'b1; end
            if (pop)  rp <= rp + 1'b1;
            count <= count + {{AW{1'b0}}, push} - {{AW{1'b0}}, pop};
        end
    end
endmodule

`default_nettype wire
