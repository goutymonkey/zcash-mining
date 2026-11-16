// Leaf-hash unit test: every vector's digest must match hashlib.
module tb_hash;
    parameter integer N = 48, K = 5, NV = 64, SPLIT = 1;
    localparam integer HOUT = (512 / N) * N / 8;
    reg clk = 0, rst = 1;
    always #5 clk = ~clk;

    reg [1119:0]     hdrs [0:NV-1];
    reg [31:0]       gs   [0:NV-1];
    reg [8*HOUT-1:0] digs [0:NV-1];
    reg [1119:0] hdr;
    reg [31:0]   g;
    reg mid_start = 0, hash_start = 0;
    wire mid_done, hash_done;
    wire [8*HOUT-1:0] dig;

    zeq_eh_hash #(.N(N), .K(K), .SPLIT(SPLIT)) dut (
        .clk(clk), .rst(rst), .hdr(hdr), .mid_start(mid_start), .mid_done(mid_done),
        .hash_start(hash_start), .flush(1'b0), .g(g), .hash_done(hash_done), .dig(dig));

    integer v, errors = 0, cycles;
    initial begin
        $readmemh("hash_hdr.hex", hdrs);
        $readmemh("hash_g.hex", gs);
        $readmemh("hash_dig.hex", digs);
        repeat (3) @(posedge clk);
        rst <= 0;
        for (v = 0; v < NV; v = v + 1) begin
            hdr <= hdrs[v];
            g   <= gs[v];
            // midstate only when the header changes, as the chip does
            if (v == 0 || hdrs[v] != hdrs[v-1]) begin
                @(posedge clk) mid_start <= 1;
                @(posedge clk) mid_start <= 0;
                wait (mid_done);
            end
            @(posedge clk) hash_start <= 1;
            @(posedge clk) hash_start <= 0;
            cycles = 0;
            while (!hash_done) begin @(posedge clk); cycles = cycles + 1; end
            if (dig !== digs[v]) begin
                errors = errors + 1;
                $display("MISMATCH v=%0d g=%08x\n  got  %h\n  want %h", v, gs[v], dig, digs[v]);
            end
        end
        $display("tb_hash: %0d vectors, %0d errors, %0d cycles per leaf hash", NV, errors, cycles);
        if (errors != 0) $fatal(1, "tb_hash FAILED");
        $display("tb_hash PASS");
        $finish;
    end
endmodule
