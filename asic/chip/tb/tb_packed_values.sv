module tb_packed_values;
    parameter integer N=48, K=5, PW=18;
    localparam integer CB=N/(K+1), VW=N-CB, AW=5, DEPTH=17, LW=$clog2(K+1);
    reg clk=0, rst=1, we=0, re=0, pre=0, bist_start=0;
    always #5 clk=~clk;
    reg [LW-1:0] phase=0, plevel=0;
    reg [AW-1:0] waddr=0, raddr=0, paddr=0;
    reg [VW-1:0] wvalue=0;
    reg [PW-1:0] wparent=0;
    wire [VW-1:0] rvalue;
    wire [PW-1:0] pvalue;
    wire bist_done, bist_fail;
    zeq_packed_values #(.N(N),.K(K),.PW(PW),.AW(AW),.DEPTH(DEPTH)) dut (.*);
`ifdef TILE_TRACE
    packed_tile_trace #(.N(N),.K(K),.PW(PW),.AW(AW),.DEPTH(DEPTH)) trace_capture (.*);
`endif
    reg [VW-1:0] values [0:K-1][0:DEPTH-1];
    reg [PW-1:0] parents [0:K-1][0:DEPTH-1];
    reg [VW-1:0] mask;
    integer level, addr, bit_i, pass_i, expected_level;
    initial begin
        repeat (3) @(negedge clk);
        rst=0; bist_start=1;
        @(negedge clk) bist_start=0;
        wait (bist_done);
        if (bist_fail) $fatal(1,"packed-table BIST failed");
        // Two attempts overwrite stale data without reset; earlier parents
        // must survive each later write to a partially occupied word.
        for (pass_i=0; pass_i<2; pass_i=pass_i+1) begin
            for (level=0; level<K; level=level+1) begin
                @(negedge clk); phase=LW'(level); re=0; pre=0;
                mask={VW{1'b1}} >> (level*CB);
                for (addr=0; addr<DEPTH; addr=addr+1) begin
                    for (bit_i=0; bit_i<VW; bit_i=bit_i+1) values[level][addr][bit_i]=1'($urandom);
                    values[level][addr] &= mask;
                    parents[level][addr]=PW'($urandom);
                    waddr=AW'(addr); wvalue=values[level][addr]; wparent=parents[level][addr]; we=1;
                    @(negedge clk);
                end
                we=0; phase=LW'(level+1);
                for (addr=0; addr<DEPTH; addr=addr+1) begin
                    re=1; raddr=AW'(addr);
                    @(negedge clk);
                    if (rvalue !== values[level][addr]) $fatal(1,"value mismatch level=%0d addr=%0d",level,addr);
                end
                re=0;
            end
            // Concurrent reads deliberately use different row addresses.
            phase=LW'(K);
            for (level=1; level<K; level=level+1) begin
                for (addr=0; addr<DEPTH; addr=addr+1) begin
                    pre=1; plevel=LW'(level); paddr=AW'(addr);
                    re=1; raddr=AW'((addr+3)%DEPTH);
                    @(negedge clk);
                    if (pvalue !== parents[level][addr]) $fatal(1,"retained parent mismatch level=%0d addr=%0d",level,addr);
                    if (rvalue !== values[K-1][(addr+3)%DEPTH]) $fatal(1,"concurrent value mismatch");
                end
            end
            re=0; pre=0;
        end
        $display("packed values N=%0d K=%0d PW=%0d slices=%0d: BIST, all rounds, parent retention, concurrent reads and reuse PASS",N,K,PW,dut.SLICES);
        $finish;
    end
    initial begin
        #1000000 $fatal(1,"packed-table timeout");
    end
endmodule
