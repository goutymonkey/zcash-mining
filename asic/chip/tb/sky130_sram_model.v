// Cycle model of the OpenRAM sky130_sram_2kbyte_1rw1r_32x512_8 macro for
// simulation (the PDK model relies on # delays and $display tracing). Port 0:
// inputs registered on clk0, read data driven after that edge. Port 1
// (read-only) is modelled but unused by the design.
module sky130_sram_2kbyte_1rw1r_32x512_8 (
    input  wire        clk0,
    input  wire        csb0,
    input  wire        web0,
    input  wire [3:0]  wmask0,
    input  wire [8:0]  addr0,
    input  wire [31:0] din0,
    output reg  [31:0] dout0,
    input  wire        clk1,
    input  wire        csb1,
    input  wire [8:0]  addr1,
    output reg  [31:0] dout1
);
    reg [31:0] mem [0:511];
    integer b;
    always @(posedge clk0) if (!csb0) begin
        if (!web0) begin
            for (b = 0; b < 4; b = b + 1)
                if (wmask0[b]) mem[addr0][8*b +: 8] <= din0[8*b +: 8];
        end else dout0 <= mem[addr0];
    end
    always @(posedge clk1) if (!csb1) dout1 <= mem[addr1];
endmodule
