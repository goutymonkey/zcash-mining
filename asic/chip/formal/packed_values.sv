// Symbolic data/address check against separate per-round reference tables.
// Inductive contract covers legal round progress, stalls, reset and new jobs.
module packed_values_formal #(
    parameter integer N=48, K=5, PW=18, AW=1, DEPTH=2,
    parameter integer CB=N/(K+1), VW=N-CB, LW=$clog2(K+1),
    // -1 checks the whole word; -2 disables that output for bitwise runs.
    parameter integer VALUE_BIT=-1, PARENT_BIT=-1
) (
    input wire clk, rst,
    input wire [LW-1:0] phase, plevel,
    input wire we, re, pre,
    input wire [AW-1:0] waddr, raddr, paddr,
    input wire [VW-1:0] wvalue,
    input wire [PW-1:0] wparent
);
    wire [VW-1:0] rvalue;
    wire [PW-1:0] pvalue;
`ifdef PACKED_PROOF
    wire [K*DEPTH*VW-1:0] proof_values;
    wire [K*DEPTH*PW-1:0] proof_parents;
    wire proof_bist_active;
`endif
    zeq_packed_values #(.N(N),.K(K),.PW(PW),.AW(AW),.DEPTH(DEPTH)) dut (
        .clk(clk),.rst(rst),.phase(phase),.we(we),.waddr(waddr),.wvalue(wvalue),.wparent(wparent),
        .re(re),.raddr(raddr),.rvalue(rvalue),.pre(pre),.plevel(plevel),.paddr(paddr),.pvalue(pvalue),
        .bist_start(1'b0),.bist_done(),.bist_fail()
`ifdef PACKED_PROOF
        ,.proof_values(proof_values),.proof_parents(proof_parents)
        ,.proof_bist_active(proof_bist_active)
`endif
    );
    reg [VW-1:0] values [0:DEPTH*K-1];
    reg [PW-1:0] parents [0:DEPTH*K-1];
    reg [DEPTH*K-1:0] valid;
    reg value_check=0, parent_check=0;
    reg [VW-1:0] expected_value;
    reg [PW-1:0] expected_parent;
    reg past_valid=0;
`ifdef PACKED_PROOF
    // BIST is never started in this contract. Prove its inactive state so
    // induction cannot invent a test engine that overwrites live data.
    always @(posedge clk) if(past_valid && !rst) assert(!proof_bist_active);
    genvar level, row;
    generate for(level=0;level<K;level=level+1) begin : g_invariant
        for(row=0;row<DEPTH;row=row+1) begin : g_row
            // Sample with the protocol assumptions below. A combinational
            // check would observe the next unconstrained phase before its
            // clocked legality assumption has taken effect in the SAT model.
            always @(posedge clk) if(past_valid && !rst &&
                !(phase==0 && $past(phase)!=0) && valid[level*DEPTH+row]) begin
                assert(level<=32'(phase));
                // Only the current and previous value generations remain live.
                if(level==32'(phase) || level+1==32'(phase))
                    assert(proof_values[(level*DEPTH+row)*VW +: VW]==values[level*DEPTH+row]);
                if(level!=0)
                    assert(proof_parents[(level*DEPTH+row)*PW +: PW]==parents[level*DEPTH+row]);
            end
        end
    end endgenerate
`endif
    always @(posedge clk) begin
        past_valid <= 1;
        if (!past_valid) assume(rst);
        assume(32'(phase)<=K);
        if (we) assume(32'(waddr)<DEPTH);
        if (re) assume(32'(raddr)<DEPTH);
        if (pre) assume(32'(paddr)<DEPTH);
        if (rst) begin
            assume(phase==0);
            assume(!we && !re && !pre);
            valid<=0;
        end else begin
            // A drop to phase zero starts another attempt, including a
            // cancellation. SRAM is deliberately not reset between jobs.
            assume(phase==0 || phase == $past(phase) || 32'(phase) == 32'($past(phase))+1);
            if (phase==0 && $past(phase)!=0) valid<=0;
            if (we) assume(32'(phase)<K);
            if (re) assume(phase!=0);
            if (pre) assume(32'(phase)==K && plevel!=0 && 32'(plevel)<K);
            if (we) begin
                values[32'(phase)*DEPTH+32'(waddr)] <= wvalue & ({VW{1'b1}} >> (32'(phase)*CB));
                parents[32'(phase)*DEPTH+32'(waddr)] <= wparent;
                valid[32'(phase)*DEPTH+32'(waddr)] <= 1;
            end
        end
        value_check <= !rst && re && valid[(32'(phase)-1)*DEPTH+32'(raddr)];
        parent_check <= !rst && pre && valid[32'(plevel)*DEPTH+32'(paddr)];
        expected_value <= values[(32'(phase)-1)*DEPTH+32'(raddr)];
        expected_parent <= parents[32'(plevel)*DEPTH+32'(paddr)];
        if (value_check) begin
            if (VALUE_BIT == -1) assert(rvalue==expected_value);
            else if (VALUE_BIT >= 0) assert(rvalue[VALUE_BIT]==expected_value[VALUE_BIT]);
        end
        if (parent_check) begin
            if (PARENT_BIT == -1) assert(pvalue==expected_parent);
            else if (PARENT_BIT >= 0) assert(pvalue[PARENT_BIT]==expected_parent[PARENT_BIT]);
        end
    end
endmodule
