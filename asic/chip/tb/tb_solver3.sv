// Solver unit test: run the RTL solver on NH headers and log every
// solution and the per-attempt count; check_solver.py compares the log
// bit-exactly with the reference model and runs both verifiers.
module tb_solver3;
    parameter integer N = 48, K = 5, NH = 8, LAT = 1, STALL = 0, D = 8;
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
    zeq_eh_solver3 #(.N(N), .K(K), .D(D)) u_solver (
        .clk(clk), .rst(rst), .start(start), .cancel(1'b0), .busy(busy), .done(done),
        .nsol(nsol), .hreq(hreq), .hg(hg), .hdone(hdone), .hdig(hdig),
        .sol_avail(sol_avail), .sol_ack(sol_ack), .sol_raddr(sol_raddr),
        .sol_rdata(sol_rdata),
        .val_req_valid(vq_v), .val_req_ready(vq_r), .val_req_we(vq_w), .val_req_addr(vq_a),
        .val_req_wdata(vq_d), .val_rsp_valid(vr_v), .val_rsp_rdata(vr_d),
        .ptr_req_valid(pq_v), .ptr_req_ready(pq_r), .ptr_req_we(pq_w), .ptr_req_addr(pq_a),
        .ptr_req_wdata(pq_d), .ptr_rsp_valid(pr_v), .ptr_rsp_rdata(pr_d),
        .ord_req_valid(oq_v), .ord_req_ready(oq_r), .ord_req_we(oq_w), .ord_req_addr(oq_a),
        .ord_req_wdata(oq_d), .ord_rsp_valid(or_v), .ord_rsp_rdata(or_d));

    // table memories (sized from the solver's own parameters)
    localparam integer INIT = 1 << (CB + 1), CAP = 2 * INIT, CW = CB + 3;
    localparam integer VVA = CB + 3, PVA = $clog2((K - 1) * CAP);
    wire vq_v, vq_r, vq_w, vr_v, pq_v, pq_r, pq_w, pr_v;
    wire oq_v, oq_r, oq_w, or_v;
    wire [VVA-1:0] vq_a;  wire [N-1:0] vq_d, vr_d;
    wire [PVA-1:0] pq_a;  wire [2*RW-1:0] pq_d, pr_d;
    wire [RW-1:0] oq_a, oq_d, or_d;
    zeq_mem_model #(.AW(VVA), .DW(N), .DEPTH(2 * CAP), .LAT(LAT), .STALL_PCT(STALL), .SEED(11)) m_val (
        .clk(clk), .req_valid(vq_v), .req_ready(vq_r), .req_we(vq_w), .req_addr(vq_a),
        .req_wdata(vq_d), .rsp_valid(vr_v), .rsp_rdata(vr_d));
    zeq_mem_model #(.AW(PVA), .DW(2 * RW), .DEPTH((K - 1) * CAP), .LAT(LAT), .STALL_PCT(STALL), .SEED(23)) m_ptr (
        .clk(clk), .req_valid(pq_v), .req_ready(pq_r), .req_we(pq_w), .req_addr(pq_a),
        .req_wdata(pq_d), .rsp_valid(pr_v), .rsp_rdata(pr_d));
    zeq_mem_model #(.AW(RW), .DW(RW), .DEPTH(CAP), .LAT(LAT), .STALL_PCT(STALL), .SEED(37)) m_ord (
        .clk(clk), .req_valid(oq_v), .req_ready(oq_r), .req_we(oq_w), .req_addr(oq_a),
        .req_wdata(oq_d), .rsp_valid(or_v), .rsp_rdata(or_d));


    integer h, w, fd, cycles, total_cycles = 0;

    // ---- profiling: memory traffic per port and cycles per phase
    /* verilator lint_off BLKSEQ */
    longint n_vr = 0, n_vw = 0, n_pr = 0, n_pw = 0, n_or = 0, n_ow = 0, n_hr = 0, n_hw = 0;
    longint c_gen = 0, c_clr = 0, c_hist = 0, c_psum = 0, c_scat = 0, c_col = 0, c_pair = 0, c_cand = 0;
    always @(posedge clk) if (!rst) begin
        if (vq_v && vq_r) begin if (vq_w) n_vw++; else n_vr++; end
        if (pq_v && pq_r) begin if (pq_w) n_pw++; else n_pr++; end
        if (oq_v && oq_r) begin if (oq_w) n_ow++; else n_or++; end
        if (u_solver.busy) begin
            case (u_solver.ph)
                2: c_gen++;
                4: c_clr++;
                5: c_hist++;
                6: c_psum++;
                7: c_scat++;
                8: c_col++;
                10: c_cand++;
                default: c_pair++;
            endcase
        end
    end
    /* verilator lint_on BLKSEQ */
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
        fd = $fopen("solver3_profile.txt", "w");
        $fwrite(fd, "port val  reads %0d writes %0d (width %0d bits)\n", n_vr, n_vw, N);
        $fwrite(fd, "port ptr  reads %0d writes %0d (width %0d bits)\n", n_pr, n_pw, 2 * RW);
        $fwrite(fd, "port ord  reads %0d writes %0d (width %0d bits)\n", n_or, n_ow, RW);
                $fwrite(fd, "phase gen %0d clr %0d hist %0d psum %0d scat %0d col+pair %0d other %0d cand %0d\n",
                c_gen, c_clr, c_hist, c_psum, c_scat, c_col, c_pair, c_cand);
        $fclose(fd);
        $display("tb_solver3 (LAT=%0d STALL=%0d%% D=%0d): %0d attempts, avg %0d cycles/attempt", LAT, STALL, D, NH, total_cycles / NH);
        $finish;
    end
    initial begin
        #(64'd50_000_000_000) $fatal(1, "tb_solver3 TIMEOUT");  // 5G cycles
    end
endmodule
