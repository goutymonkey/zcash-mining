// Solver unit test: run the RTL solver on NH headers and log every
// solution and the per-attempt count; check_solver.py compares the log
// bit-exactly with the reference model and runs both verifiers.
module tb_par;
    parameter integer N = 48, K = 5, NH = 8, BB = 4, PB = 2, SB = 6, HPB = PB, HASH_SPLIT = 1, STAGED_NETWORK = 0, PACKED_TABLES = 0, SPLIT_KEYS = 0, COMPACT_VALUES = 0, SLOTS = 1 << SB, BIST_FIRST = 0;
    parameter integer GMAX = 16, GROUP_REPLAY = 0;
    parameter integer TRACE_DROPS = 0;
    parameter integer TILE_TRACE_ENGINE = -1;
    parameter integer BUCKET0_SLOTS = SLOTS;
    parameter integer DROP_ZERO = 0;
    parameter integer LEAF_SET = 0;
    parameter integer HASH_UNITS = 1;
    parameter integer CHAIN = 0;
    parameter integer GBUF = 2;
    parameter integer QDEPTH = 4;
    parameter integer EMIT = 1;
    localparam integer IPHO = 512 / N, HOUT = IPHO * N / 8;
    localparam integer CB = N / (K + 1), RW = CB + 2, NSOL = 1 << K;
    reg clk = 0, rst = 1;
    always #5 clk = ~clk;

    reg  [1119:0] hdrs [0:NH-1];
    reg  [1119:0] hdr;
    reg  mid_start = 0, start = 0, sol_ack = 0;
    reg  [K-1:0] sol_raddr = 0;
    wire mid_done, busy, done, sol_avail;
    wire [7:0] nsol;
    wire [RW-1:0] sol_rdata;

    reg bist_start = 0;
    wire bist_done, bist_fail;
    wire [15:0] dropped;
    zeq_eh_par #(.GMAX(GMAX), .GROUP_REPLAY(GROUP_REPLAY), .N(N), .K(K), .BB(BB), .PB(PB), .SB(SB), .HPB(HPB), .SPLIT(HASH_SPLIT), .STAGED_NETWORK(STAGED_NETWORK), .PACKED_TABLES(PACKED_TABLES), .SPLIT_KEYS(SPLIT_KEYS), .COMPACT_VALUES(COMPACT_VALUES), .SLOTS(SLOTS), .BUCKET0_SLOTS(BUCKET0_SLOTS), .DROP_ZERO(DROP_ZERO), .LEAF_SET(LEAF_SET), .HASH_UNITS(HASH_UNITS), .CHAIN(CHAIN), .GBUF(GBUF), .QDEPTH(QDEPTH), .EMIT(EMIT)) u_solver (
        .clk(clk), .rst(rst), .hdr(hdr), .mid_start(mid_start), .mid_done(mid_done),
        .start(start), .cancel(1'b0), .busy(busy), .done(done), .nsol(nsol),
        .dropped(dropped), .sol_avail(sol_avail), .sol_ack(sol_ack),
        .sol_raddr(sol_raddr), .sol_rdata(sol_rdata),
        .bist_start(bist_start), .bist_done(bist_done), .bist_fail(bist_fail));

    generate if (TILE_TRACE_ENGINE >= 0) begin : g_tile_trace
        localparam integer E=TILE_TRACE_ENGINE;
        localparam integer TAW=BB-PB+SB;
        localparam integer TDEPTH=(1 << (BB-PB))*SLOTS + (E==0 ? BUCKET0_SLOTS-SLOTS : 0);
        packed_tile_trace #(.N(N),.K(K),.PW(BB+2*SB),.AW(TAW),.DEPTH(TDEPTH)) capture (
            .clk(clk), .rst(rst),
            .phase(u_solver.g_eng[E].g_packed.u_tables.phase),
            .we(u_solver.g_eng[E].g_packed.u_tables.we),
            .waddr(u_solver.g_eng[E].g_packed.u_tables.waddr),
            .wvalue(u_solver.g_eng[E].g_packed.u_tables.wvalue),
            .wparent(u_solver.g_eng[E].g_packed.u_tables.wparent),
            .re(u_solver.g_eng[E].g_packed.u_tables.re),
            .raddr(u_solver.g_eng[E].g_packed.u_tables.raddr),
            .pre(u_solver.g_eng[E].g_packed.u_tables.pre),
            .plevel(u_solver.g_eng[E].g_packed.u_tables.plevel),
            .paddr(u_solver.g_eng[E].g_packed.u_tables.paddr),
            .bist_start(bist_start),
            .rvalue(u_solver.g_eng[E].g_packed.u_tables.rvalue),
            .pvalue(u_solver.g_eng[E].g_packed.u_tables.pvalue),
            .bist_done(u_solver.g_eng[E].g_packed.u_tables.bist_done),
            .bist_fail(u_solver.g_eng[E].g_packed.u_tables.bist_fail));
    end endgenerate

    integer h, w, fd, drop_fd, zero_fd, cycles, total_cycles = 0;
    longint unsigned zero_discards = 0;   // all engines, current attempt
    // Shared expansion unit, current attempt: candidates taken, cycles busy,
    // cycles in the repeat-check states, and cycles spent in the last round.
    longint unsigned x_candidates = 0, x_busy_cycles = 0, x_check_cycles = 0, last_round_cycles = 0;
    longint unsigned x_leaf_rejects = 0, x_late_rejects = 0;   // repeated leaf found by the set / by the final pairwise check
    integer x_fd;
    // engine-0 cycles by state (GREQ..WK = 1..9), rows it processed
    /* verilator lint_off BLKSEQ */
    longint est [0:15];
    longint rows0 = 0, value_reads0 = 0, key_reads0 = 0, scatter_reads0 = 0;
    // Busy-window physical-port activity across every engine. These are
    // word accesses, not energy; compiler characterization supplies energy.
    longint unsigned port_reads [0:(1<<PB)-1][0:5];
    longint unsigned port_writes [0:(1<<PB)-1][0:5];
    longint unsigned network_requests [0:(1<<PB)-1];
    longint unsigned network_grants [0:(1<<PB)-1];
    longint unsigned network_stalls [0:(1<<PB)-1];
    longint unsigned bucket0_extra_writes [0:K-1];
    integer bucket0_max_slot = -1;
    integer capacity_round;
    initial for (capacity_round=0; capacity_round<K; capacity_round=capacity_round+1)
        bucket0_extra_writes[capacity_round]=0;
    always @(posedge clk) if (!rst && busy && !u_solver.fill_clr
            && u_solver.g_eng[0].wok && u_solver.g_eng[0].wbkt == 0) begin
        if (int'(u_solver.g_eng[0].wslot) > bucket0_max_slot)
            bucket0_max_slot = int'(u_solver.g_eng[0].wslot);
        if (int'(u_solver.g_eng[0].wslot) >= SLOTS)
            bucket0_extra_writes[u_solver.r] += 1;
    end
    function integer packed_slice_count;
        integer level, needed, peak;
        begin
            peak=0;
            for (level=0; level<K; level=level+1) begin
                needed=(N-(level+1)*CB+(BB+2*SB)-1)/(BB+2*SB)+(level+1)/2;
                if (needed>peak) peak=needed;
            end
            packed_slice_count=peak;
        end
    endfunction
    localparam integer PACKED_SLICES=packed_slice_count();
    longint unsigned packed_reads [0:(1<<PB)-1][0:2*PACKED_SLICES-1];
    longint unsigned packed_writes [0:(1<<PB)-1][0:2*PACKED_SLICES-1];
    longint unsigned packed_read_sum, packed_write_sum;
    integer profile_slice;
    genvar pe;
    generate for (pe = 0; pe < (1<<PB); pe = pe + 1) begin : g_profile
        if (TRACE_DROPS != 0) begin : g_drop_trace
            always @(posedge clk) if (!rst && busy && !u_solver.fill_clr
                    && u_solver.w_v[pe] && !u_solver.g_eng[pe].wok)
                $fwrite(drop_fd, "%0d,%0d,%0d,%0d,%0d,%0d,%h,%h\n",
                    h, u_solver.r, pe, u_solver.g_eng[pe].wbkt,
                    u_solver.g_eng[pe].wslot, u_solver.g_eng[pe].wlk,
                    u_solver.g_eng[pe].wval, u_solver.g_eng[pe].wfld);
        end
        integer table_i;
        initial begin
            for (table_i = 0; table_i < 6; table_i = table_i + 1) begin
                port_reads[pe][table_i] = 0;
                port_writes[pe][table_i] = 0;
            end
            network_requests[pe] = 0;
            network_grants[pe] = 0;
            network_stalls[pe] = 0;
        end
        always @(posedge clk) if (!rst && busy) begin
            port_reads[pe][0] += 64'(u_solver.g_eng[pe].m_val0.re) + 64'(u_solver.g_eng[pe].m_val1.re);
            port_writes[pe][0] += 64'(u_solver.g_eng[pe].m_val0.we) + 64'(u_solver.g_eng[pe].m_val1.we);
            port_reads[pe][2] += 64'(u_solver.g_eng[pe].m_hist0.re) + 64'(u_solver.g_eng[pe].m_hist1.re);
            port_writes[pe][2] += 64'(u_solver.g_eng[pe].m_hist0.we) + 64'(u_solver.g_eng[pe].m_hist1.we);
            if (u_solver.g_eng[pe].m_ptr.re) port_reads[pe][3] += 1;
            if (u_solver.g_eng[pe].m_ptr.we) port_writes[pe][3] += 1;
            if (u_solver.g_eng[pe].m_idx.re) port_reads[pe][4] += 1;
            if (u_solver.g_eng[pe].m_idx.we) port_writes[pe][4] += 1;
            if (u_solver.g_eng[pe].m_order.re) port_reads[pe][5] += 1;
            if (u_solver.g_eng[pe].m_order.we) port_writes[pe][5] += 1;
            if (u_solver.q_v[pe]) network_requests[pe] += 1;
            if (u_solver.q_g[pe]) network_grants[pe] += 1;
            if (u_solver.q_v[pe] && !u_solver.q_g[pe]) network_stalls[pe] += 1;
            if (u_solver.g_eng[pe].zero_discard) zero_discards += 1;
            if (u_solver.g_eng[pe].zero_discard2) zero_discards += 1;
        end
        genvar ppar, pslice;
        for (ppar=0; ppar<2; ppar=ppar+1) begin : g_packed_parity
            for (pslice=0; pslice<PACKED_SLICES; pslice=pslice+1) begin : g_packed_slice
                initial begin
                    packed_reads[pe][ppar*PACKED_SLICES+pslice]=0;
                    packed_writes[pe][ppar*PACKED_SLICES+pslice]=0;
                end
                if (PACKED_TABLES != 0) begin : g_enabled
                    always @(posedge clk) if (!rst && busy) begin
                        if (u_solver.g_eng[pe].g_packed.u_tables.g_parity[ppar].g_slice[pslice].m_slice.re)
                            packed_reads[pe][ppar*PACKED_SLICES+pslice] += 1;
                        if (u_solver.g_eng[pe].g_packed.u_tables.g_parity[ppar].g_slice[pslice].m_slice.we)
                            packed_writes[pe][ppar*PACKED_SLICES+pslice] += 1;
                    end
                end
            end
        end
        if (CHAIN != 0) begin : g_links     // chain links take the key column
            always @(posedge clk) if (!rst && busy) begin
                port_reads[pe][1] += 64'(u_solver.g_eng[pe].g_link.m_link0.re) + 64'(u_solver.g_eng[pe].g_link.m_link1.re);
                port_writes[pe][1] += 64'(u_solver.g_eng[pe].g_link.m_link0.we) + 64'(u_solver.g_eng[pe].g_link.m_link1.we);
            end
        end else if (SPLIT_KEYS != 0) begin : g_keys
            always @(posedge clk) if (!rst && busy) begin
                port_reads[pe][1] += 64'(u_solver.g_eng[pe].g_split_keys.m_key0.re) + 64'(u_solver.g_eng[pe].g_split_keys.m_key1.re);
                port_writes[pe][1] += 64'(u_solver.g_eng[pe].g_split_keys.m_key0.we) + 64'(u_solver.g_eng[pe].g_split_keys.m_key1.we);
            end
        end
    end endgenerate
    integer profile_engine;
    integer q;
    initial for (q = 0; q < 16; q = q + 1) est[q] = 0;
    always @(posedge clk) if (!rst && busy) begin
        if (u_solver.xs == 5'd1) x_candidates += 1;                 // X_A
        if (u_solver.xs != 5'd0) x_busy_cycles += 1;
        if (u_solver.xs >= 5'd18 && u_solver.xs <= 5'd20) x_check_cycles += 1;   // X_D0..X_D2
        if (int'(u_solver.r) == K) last_round_cycles += 1;
        if (u_solver.xs == 5'd24 && u_solver.h_hit) x_leaf_rejects += 1;       // X_H1
        if (u_solver.xs == 5'd20 && !u_solver.early && int'(u_solver.dlim) == NSOL
                && u_solver.xbuf_q == u_solver.xfirst) x_late_rejects += 1;                     // X_D2, full check
        est[u_solver.g_eng[0].es] += 1;
        if (u_solver.g_eng[0].value_rd) value_reads0 += 1;
        if (u_solver.g_eng[0].krd) key_reads0 += 1;
        if (u_solver.g_eng[0].krd_sc) scatter_reads0 += 1;
        if (u_solver.g_eng[0].es == 8 && u_solver.g_eng[0].v1) rows0 += 1;
    end
    /* verilator lint_on BLKSEQ */
    initial begin
        // memory inventory only (run from a scratch directory): no simulation
        if ($test$plusargs("ram_inventory")) begin #1 $finish; end
        $readmemh("solver_hdr.hex", hdrs);
        fd = $fopen("solver_out.txt", "w");
        zero_fd = $fopen("zero_rows.csv", "w");
        if (zero_fd == 0) $fatal(1, "cannot open zero-row profile");
        $fwrite(zero_fd, "attempt,discarded_zero_rows\n");
        x_fd = $fopen("expansion_profile.csv", "w");
        if (x_fd == 0) $fatal(1, "cannot open expansion profile");
        $fwrite(x_fd, "attempt,solutions,cycles,last_round_cycles,candidates,expansion_busy_cycles,repeat_check_cycles,repeated_leaf_rejects\n");
        if (TRACE_DROPS != 0) begin
            drop_fd = $fopen("dropped_rows.csv", "w");
            if (drop_fd == 0) $fatal(1, "cannot open dropped-row trace");
            $fwrite(drop_fd, "attempt,round,engine,bucket,slot,local_key,value,parent_or_leaf\n");
        end
        repeat (3) @(posedge clk);
        rst <= 0;
        if (BIST_FIRST != 0) begin
            @(posedge clk) bist_start <= 1;
            @(posedge clk) bist_start <= 0;
            wait (bist_done);
            if (bist_fail) $fatal(1, "packed-memory BIST failed");
            $display("packed-memory BIST: PASS");
        end
        for (h = 0; h < NH; h = h + 1) begin
            hdr <= hdrs[h];
            @(posedge clk) mid_start <= 1;
            @(posedge clk) mid_start <= 0;
            wait (mid_done);
            @(posedge clk) start <= 1;
            @(posedge clk) start <= 0;
            $fwrite(fd, "A %0d\n", h);
            cycles = 0;
            zero_discards = 0;
            x_candidates = 0; x_busy_cycles = 0; x_check_cycles = 0; last_round_cycles = 0;
            x_leaf_rejects = 0; x_late_rejects = 0;
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
            $fwrite(fd, "D %0d %0d %0d\n", nsol, cycles, dropped);
            $fwrite(zero_fd, "%0d,%0d\n", h, zero_discards);
            $fwrite(x_fd, "%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d\n", h, nsol, cycles, last_round_cycles,
                    x_candidates, x_busy_cycles, x_check_cycles, x_leaf_rejects + x_late_rejects);
            total_cycles = total_cycles + cycles;
        end
        $fclose(fd);
        $fclose(zero_fd);
        $fclose(x_fd);
        if (TRACE_DROPS != 0) $fclose(drop_fd);
        if (BUCKET0_SLOTS != SLOTS) begin
            fd = $fopen("bucket0_capacity.csv", "w");
            if (fd == 0) $fatal(1, "cannot open bucket-zero capacity profile");
            $fwrite(fd, "round,accepted_extra_rows\n");
            for (capacity_round=0; capacity_round<K; capacity_round=capacity_round+1)
                $fwrite(fd, "%0d,%0d\n", capacity_round, bucket0_extra_writes[capacity_round]);
            $fclose(fd);
            $display("bucket-zero highest accepted slot: %0d", bucket0_max_slot);
        end
        fd = $fopen("par_profile.txt", "w");
        $fwrite(fd, "engine0 rows %0d gen %0d bar %0d bkt %0d ca %0d ps %0d sc %0d wk %0d\n",
                rows0, est[1] + est[2] + est[3], est[4], est[5], est[6], est[7], est[8], est[9]);
        $fclose(fd);
        fd = $fopen("memory_profile.txt", "w");
        $fwrite(fd, "engine0 value_reads %0d key_reads %0d scatter_reads %0d value_width %0d key_width %0d split_keys %0d\n",
                value_reads0, key_reads0, scatter_reads0, u_solver.MW, u_solver.LB, SPLIT_KEYS);
        $fclose(fd);
        fd = $fopen("memory_accesses.csv", "w");
        $fwrite(fd, "engine,table,width_bits,read_words,write_words\n");
        for (profile_engine = 0; profile_engine < (1<<PB); profile_engine += 1) begin
            if (PACKED_TABLES != 0) begin
                packed_read_sum=0; packed_write_sum=0;
                for (profile_slice=0; profile_slice<2*PACKED_SLICES; profile_slice+=1) begin
                    packed_read_sum += packed_reads[profile_engine][profile_slice];
                    packed_write_sum += packed_writes[profile_engine][profile_slice];
                end
                $fwrite(fd, "%0d,packed_values_and_parents,%0d,%0d,%0d\n", profile_engine, BB+2*SB, packed_read_sum, packed_write_sum);
            end
            $fwrite(fd, "%0d,value,%0d,%0d,%0d\n", profile_engine, u_solver.MW, port_reads[profile_engine][0], port_writes[profile_engine][0]);
            $fwrite(fd, "%0d,key,%0d,%0d,%0d\n", profile_engine, u_solver.LB, port_reads[profile_engine][1], port_writes[profile_engine][1]);
            $fwrite(fd, "%0d,histogram,%0d,%0d,%0d\n", profile_engine, SB+1, port_reads[profile_engine][2], port_writes[profile_engine][2]);
            $fwrite(fd, "%0d,parents,%0d,%0d,%0d\n", profile_engine, u_solver.PW, port_reads[profile_engine][3], port_writes[profile_engine][3]);
            $fwrite(fd, "%0d,leaf_indices,%0d,%0d,%0d\n", profile_engine, u_solver.IW, port_reads[profile_engine][4], port_writes[profile_engine][4]);
            $fwrite(fd, "%0d,order,%0d,%0d,%0d\n", profile_engine, SB, port_reads[profile_engine][5], port_writes[profile_engine][5]);
        end
        $fclose(fd);
        fd = $fopen("network_activity.csv", "w");
        $fwrite(fd, "engine,request_cycles,grants,stall_cycles\n");
        for (profile_engine = 0; profile_engine < (1<<PB); profile_engine += 1)
            $fwrite(fd, "%0d,%0d,%0d,%0d\n", profile_engine, network_requests[profile_engine], network_grants[profile_engine], network_stalls[profile_engine]);
        $fclose(fd);
        $display("tb_par (P=%0d): %0d attempts, avg %0d cycles/attempt", 1 << PB, NH, total_cycles / NH);
        $finish;
    end
    initial begin
        #(64'd50_000_000_000) $fatal(1, "tb_par TIMEOUT");  // 5G cycles
    end
endmodule
