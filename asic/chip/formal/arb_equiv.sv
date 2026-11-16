module arb_equiv #(
    parameter integer PB = 2,
    parameter integer BANK = 1
)(input wire clk, rst,
  input wire [(1<<PB)-1:0] req,
  input wire [(1<<PB)*PB-1:0] tgt);
    wire a_v, b_v;
    wire [PB-1:0] a_sel, b_sel;
    zeq_xbar_arb #(.PB(PB), .BANK(BANK)) revised (
        .clk(clk), .rst(rst), .req(req), .tgt(tgt), .gv(a_v), .gsel(a_sel));
    zeq_xbar_arb_reference #(.PB(PB), .BANK(BANK)) reference (
        .clk(clk), .rst(rst), .req(req), .tgt(tgt), .gv(b_v), .gsel(b_sel));
    reg valid = 0;
    always @(posedge clk) if (rst) valid <= 1;
    always @* if (valid) begin
        assert(a_v == b_v);
        assert(a_sel == b_sel);
    end
endmodule
