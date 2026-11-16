// Pre-edge interface samples: includes every idle, reset and BIST cycle.
module packed_tile_trace #(
    parameter integer N=200, K=9, PW=32, AW=18, DEPTH=163840,
    parameter integer VW=N-N/(K+1), LW=$clog2(K+1)
) (
    input wire clk, rst,
    input wire [LW-1:0] phase,
    input wire we,
    input wire [AW-1:0] waddr,
    input wire [VW-1:0] wvalue,
    input wire [PW-1:0] wparent,
    input wire re,
    input wire [AW-1:0] raddr,
    input wire pre,
    input wire [LW-1:0] plevel,
    input wire [AW-1:0] paddr,
    input wire bist_start,
    input wire [VW-1:0] rvalue,
    input wire [PW-1:0] pvalue,
    input wire bist_done, bist_fail
);
    integer trace_fd;
    longint unsigned trace_cycle=0;
    initial begin
        trace_fd=$fopen("packed_tile.trace", "w");
        if (trace_fd==0) $fatal(1,"cannot open tile trace");
        $fdisplay(trace_fd,"ZEQ_TILE_V1 %0d %0d %0d %0d %0d",N,K,PW,AW,DEPTH);
    end
    /* verilator lint_off BLKSEQ */
    always @(posedge clk) begin
        $fdisplay(trace_fd,"%0d %h",trace_cycle,
            {rst,phase,we,waddr,wvalue,wparent,re,raddr,pre,plevel,paddr,bist_start,
             rvalue,pvalue,bist_done,bist_fail});
        trace_cycle=trace_cycle+1;
    end
    /* verilator lint_on BLKSEQ */
    final begin
        $fdisplay(trace_fd,"END %0d",trace_cycle);
        $fclose(trace_fd);
    end
endmodule
