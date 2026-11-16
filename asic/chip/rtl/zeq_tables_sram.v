// On-chip table memories behind the solver's ports (always ready, one
// cycle read latency). Used when the tables fit on die (test parameters);
// the mainnet die routes the same ports to a DRAM controller instead.
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
    output reg  [DW-1:0] rsp_rdata
);
    reg [DW-1:0] mem [0:DEPTH-1];
    assign req_ready = 1'b1;
    always @(posedge clk) begin
        rsp_valid <= req_valid & ~req_we;
        if (req_valid) begin
            if (req_we) mem[req_addr] <= req_wdata;
            else rsp_rdata <= mem[req_addr];
        end
    end
endmodule

`default_nettype wire
