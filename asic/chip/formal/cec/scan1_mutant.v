// MUTANT for ./run.sh lec: the scanned block with scan mode left ON (scan_en = 1); must NOT be equivalent
module zeq_blake2b_func (input clk, input rst, input start, input [511:0] h_in,
    input [1023:0] m, input [63:0] t, input last, output done, output [511:0] h_out);
    wire so;
    zeq_blake2b_scan u (.scan_en(1'b1), .scan_in(1'b0), .scan_out(so), .clk(clk), .rst(rst),
        .start(start), .h_in(h_in), .m(m), .t(t), .last(last), .done(done), .h_out(h_out));
endmodule
