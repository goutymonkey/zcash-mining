// Round-robin arbiter for one crossbar bank: among the P engines whose
// request targets this bank (bucket % P == BANK), grant the first at or
// after the round-robin pointer; the pointer then moves past the winner.
`default_nettype none

module zeq_xbar_arb #(
    parameter integer PB   = 2,
    parameter integer BANK = 0
) (
    input  wire              clk,
    input  wire              rst,
    input  wire [(1<<PB)-1:0]      req,     // request valid
    input  wire [(1<<PB)*PB-1:0]   tgt,     // requested bank per engine
    output reg               gv,             // a grant this cycle
    output reg  [PB-1:0]     gsel            // granted engine
);
    localparam integer P = 1 << PB;
    reg [PB-1:0] rr;
    integer k, idx;
    always @* begin
        gv = 1'b0;
        gsel = 0;
        for (k = P - 1; k >= 0; k = k - 1) begin
            idx = ({{(32-PB){1'b0}}, rr} + k) % P;
            if (req[idx] && tgt[idx*PB +: PB] == BANK[PB-1:0]) begin
                gv = 1'b1;
                gsel = idx[PB-1:0];
            end
        end
    end
    always @(posedge clk)
        if (rst) rr <= 0;
        else if (gv) rr <= gsel + 1'b1;

`ifdef FORMAL
    // ---- properties (proved in formal/arb.ys)
    reg init = 1'b1;
    always @(posedge clk) init <= 1'b0;
    // a grant only goes to a requester of this bank
    always @* if (gv) assert (req[gsel] && tgt[gsel*PB +: PB] == BANK[PB-1:0]);
    // any requester of this bank means a grant this cycle (work conserving)
    reg any;
    integer a;
    always @* begin
        any = 1'b0;
        for (a = 0; a < P; a = a + 1) if (req[a] && tgt[a*PB +: PB] == BANK[PB-1:0]) any = 1'b1;
        assert (gv == any);
    end
    // fairness: engine 0 holding a request to this bank is granted within P cycles
    reg [PB+1:0] wait0;
    always @(posedge clk)
        if (rst || init) wait0 <= 0;
        else if (req[0] && tgt[PB-1:0] == BANK[PB-1:0] && !(gv && gsel == 0)) wait0 <= wait0 + 1'b1;
        else wait0 <= 0;
    always @* if (!init) assert (wait0 < P);
`endif
endmodule

`default_nettype wire
