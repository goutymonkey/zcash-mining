// Replay checks functional equivalence only; no technology power/timing claim.
module tb_packed_tile_replay;
    parameter integer N=200, K=9, PW=32, AW=18, DEPTH=163840;
    localparam integer VW=N-N/(K+1), LW=$clog2(K+1);
    localparam integer BITS=7+2*LW+3*AW+2*VW+2*PW;
    reg clk=0, rst;
    reg [LW-1:0] phase, plevel;
    reg we,re,pre,bist_start;
    reg [AW-1:0] waddr,raddr,paddr;
    reg [VW-1:0] wvalue;
    reg [PW-1:0] wparent;
    wire [VW-1:0] rvalue;
    wire [PW-1:0] pvalue;
    wire bist_done,bist_fail;
    reg [VW+PW+1:0] expected;
    reg [BITS-1:0] sample_bits;
    integer fd,rc,hn,hk,hpw,haw,hdepth;
    longint unsigned cycle_index, expected_cycle=0, end_cycle;
    reg completed=0;
    string line;
    zeq_packed_values #(.N(N),.K(K),.PW(PW),.AW(AW),.DEPTH(DEPTH)) dut (.*);
    initial begin
        fd=$fopen("packed_tile.trace","r");
        if (fd==0) $fatal(1,"missing tile trace");
        rc=$fscanf(fd,"ZEQ_TILE_V1 %d %d %d %d %d\n",hn,hk,hpw,haw,hdepth);
        if (rc!=5 || hn!=N || hk!=K || hpw!=PW || haw!=AW || hdepth!=DEPTH)
            $fatal(1,"trace geometry mismatch");
        while ($fgets(line,fd)!=0) begin
            rc=$sscanf(line,"END %d",end_cycle);
            if (rc==1) begin
                if (end_cycle!=expected_cycle || expected_cycle==0) $fatal(1,"bad trace footer");
                if ($fgets(line,fd)!=0) $fatal(1,"data after trace footer");
                $fclose(fd);
                completed=1;
                $display("TILE_REPLAY_PASS cycles=%0d",expected_cycle);
                $finish;
                break;
            end else begin
                rc=$sscanf(line,"%d %h",cycle_index,sample_bits);
                if (rc!=2 || cycle_index!=expected_cycle) $fatal(1,"bad trace cycle");
                {rst,phase,we,waddr,wvalue,wparent,re,raddr,pre,plevel,paddr,bist_start,
                 expected}=sample_bits;
                #4;
                if ({rvalue,pvalue,bist_done,bist_fail} !== expected)
                    $fatal(1,"tile replay mismatch at cycle %0d",cycle_index);
                #1 clk=1;
                #5 clk=0;
                expected_cycle=expected_cycle+1;
            end
        end
        if (!completed) $fatal(1,"tile trace lacks completion footer");
    end
endmodule
