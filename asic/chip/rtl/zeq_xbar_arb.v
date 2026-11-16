// Round-robin arbiter for one crossbar bank: among the P engines whose
// request targets this bank (bucket % P == BANK), grant the first at or
// after the round-robin pointer; the pointer then moves past the winner.
`default_nettype none

module zeq_xbar_arb #(
    parameter integer PB   = 2,
    parameter integer BANK = 0,
    parameter integer TB = PB // destination width may differ in staged fabrics
) (
    input  wire              clk,
    input  wire              rst,
    input  wire [(1<<PB)-1:0]      req,     // request valid
    input  wire [(1<<PB)*TB-1:0]   tgt,     // requested bank per engine
    output reg               gv,             // a grant this cycle
    output reg  [PB-1:0]     gsel            // granted engine
`ifdef NETWORK_PROOF
    ,output wire [PB-1:0] proof_rr
`endif
);
    localparam integer P = 1 << PB;
    reg [PB-1:0] rr;
`ifdef NETWORK_PROOF
    assign proof_rr=rr;
`endif
    // Compare each source with this bank once, then use two balanced
    // priority trees: eligible sources at/above rr, and all sources for
    // wraparound. No variable-index scan of request/target buses.
    wire [2*P-1:1] any_valid, masked_valid;
    wire [PB-1:0] any_index [1:2*P-1];
    wire [PB-1:0] masked_index [1:2*P-1];
    genvar i;
    generate
        for (i = 0; i < P; i = i + 1) begin : g_leaf
            assign any_valid[P+i] = req[i] && tgt[i*TB +: TB] == BANK[TB-1:0];
            if (i == P-1) begin : g_last
                assign masked_valid[P+i] = any_valid[P+i];
            end else begin : g_mask
                assign masked_valid[P+i] = any_valid[P+i] && i[PB-1:0] >= rr;
            end
            assign any_index[P+i] = i[PB-1:0];
            assign masked_index[P+i] = i[PB-1:0];
        end
        for (i = 1; i < P; i = i + 1) begin : g_tree
            assign any_valid[i] = any_valid[2*i] || any_valid[2*i+1];
            assign masked_valid[i] = masked_valid[2*i] || masked_valid[2*i+1];
            assign any_index[i] = any_valid[2*i] ? any_index[2*i] : any_index[2*i+1];
            assign masked_index[i] = masked_valid[2*i] ? masked_index[2*i] : masked_index[2*i+1];
        end
    endgenerate
    always @* begin
        gv = any_valid[1];
        gsel = !any_valid[1] ? {PB{1'b0}} :
               (masked_valid[1] ? masked_index[1] : any_index[1]);
    end
    always @(posedge clk)
        if (rst) rr <= 0;
        else if (gv) rr <= gsel + 1'b1;

`ifdef FORMAL
    // ---- properties (proved in formal/arb.ys)
    reg init = 1'b1;
    always @(posedge clk) init <= 1'b0;
    // a grant only goes to a requester of this bank
    always @* if (gv) assert (req[gsel] && tgt[gsel*TB +: TB] == BANK[TB-1:0]);
    // any requester of this bank means a grant this cycle (work conserving)
    reg any;
    integer a;
    always @* begin
        any = 1'b0;
        for (a = 0; a < P; a = a + 1) if (req[a] && tgt[a*TB +: TB] == BANK[TB-1:0]) any = 1'b1;
        assert (gv == any);
    end
    // fairness: engine 0 holding a request to this bank is granted within P cycles
    reg [PB+1:0] wait0;
    always @(posedge clk)
        if (rst || init) wait0 <= 0;
        else if (req[0] && tgt[TB-1:0] == BANK[TB-1:0] && !(gv && gsel == 0)) wait0 <= wait0 + 1'b1;
        else wait0 <= 0;
    always @* if (!init) assert (wait0 < P);
`endif
endmodule

`default_nettype wire
