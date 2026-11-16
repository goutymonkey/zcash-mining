// Solver unit test: run the RTL solver on NH headers and log every
// solution and the per-attempt count; check_solver.py compares the log
// bit-exactly with the reference model and runs both verifiers.
module tb_solver;
    parameter integer N = 48, K = 5, NH = 8;
    localparam integer IPHO = 512 / N, HOUT = IPHO * N / 8;
    localparam integer CB = N / (K + 1), RW = CB + 2, NSOL = 1 << K;
    reg clk = 0, rst = 1;
    always #5 clk = ~clk;

    reg  [1119:0] hdrs [0:NH-1];
    reg  [1119:0] hdr;
    reg  mid_start = 0, start = 0, sol_ack = 0;
    reg  [K-1:0] sol_raddr = 0;
    wire mid_done, hreq, hdone, busy, done, sol_avail;
    wire [31:0] hg;
    wire [8*HOUT-1:0] hdig;
    wire [7:0] nsol;
    wire [RW-1:0] sol_rdata;

    zeq_eh_hash #(.N(N), .K(K)) u_hash (
        .clk(clk), .rst(rst), .hdr(hdr), .mid_start(mid_start), .mid_done(mid_done),
        .hash_start(hreq), .flush(1'b0), .g(hg), .hash_done(hdone), .dig(hdig));
    zeq_eh_solver #(.N(N), .K(K)) u_solver (
        .clk(clk), .rst(rst), .start(start), .abort(1'b0), .busy(busy), .done(done),
        .nsol(nsol), .hreq(hreq), .hg(hg), .hdone(hdone), .hdig(hdig),
        .sol_avail(sol_avail), .sol_ack(sol_ack), .sol_raddr(sol_raddr),
        .sol_rdata(sol_rdata));

    integer h, w, fd, cycles, total_cycles = 0;
    initial begin
        $readmemh("solver_hdr.hex", hdrs);
        fd = $fopen("solver_out.txt", "w");
        repeat (3) @(posedge clk);
        rst <= 0;
        for (h = 0; h < NH; h = h + 1) begin
            hdr <= hdrs[h];
            @(posedge clk) mid_start <= 1;
            @(posedge clk) mid_start <= 0;
            wait (mid_done);
            @(posedge clk) start <= 1;
            @(posedge clk) start <= 0;
            $fwrite(fd, "A %0d\n", h);
            cycles = 0;
            while (!done) begin
                @(posedge clk);
                cycles = cycles + 1;
                if (sol_avail && !sol_ack) begin
                    $fwrite(fd, "S");
                    for (w = 0; w < NSOL; w = w + 1) begin
                        sol_raddr <= w[K-1:0];
                        @(posedge clk); @(posedge clk);   // registered read
                        #1 $fwrite(fd, " %0d", sol_rdata);
                        cycles = cycles + 2;
                    end
                    $fwrite(fd, "\n");
                    @(posedge clk) sol_ack <= 1;
                    @(posedge clk) sol_ack <= 0;
                end
            end
            $fwrite(fd, "D %0d %0d\n", nsol, cycles);
            total_cycles = total_cycles + cycles;
        end
        $fclose(fd);
        $display("tb_solver: %0d attempts, avg %0d cycles/attempt", NH, total_cycles / NH);
        $finish;
    end
    initial begin
        #(64'd5_000_000_000) $fatal(1, "tb_solver TIMEOUT");  // 500M cycles
    end
endmodule
