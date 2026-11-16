// Equihash (N,K) solver: Wagner's algorithm with parent-pointer tables.
//
// Rows never carry index lists. Level 0 row i is leaf i; a level-r row
// stores the remaining hash bits and two pointers to its level r-1
// parents. Each round:
//   CLR/HIST/PSUM/SCAT  stable counting sort of the source level by its
//                       next CB-bit collision chunk (histogram, prefix sum,
//                       scatter into an order table)
//   COL/PAIR            walk runs of equal keys (first GMAX kept) and emit
//                       every pair: XOR of the remaining bits + parent ptrs
// The last round only pairs rows whose final 2*CB bits are equal. Each such
// candidate is expanded down the pointer tree to 2^K leaf indices (EXP),
// put in zcash canonical order (ORD/SWP), checked for repeated indices
// (D), and handed to the link through xbuf (EMIT).
//
// All memories are single-port with registered reads, so they map
// directly onto SRAM macros. The algorithm is mirrored step for step by
// model/equihash_ref.py:hw_solve, which the testbenches compare against.
`default_nettype none

module zeq_eh_solver #(
    parameter integer N    = 48,
    parameter integer K    = 5,
    parameter integer GMAX = 16,  // rows kept per collision group (see README: yield)
    // derived (do not override)
    parameter integer CB   = N / (K + 1),
    parameter integer INIT = 1 << (CB + 1),
    parameter integer IPHO = 512 / N,
    parameter integer HOUT = IPHO * N / 8,
    parameter integer CAP  = 2 * INIT,       // rows per level
    parameter integer RW   = CB + 2,         // row pointer width
    parameter integer NSOL = 1 << K
) (
    input  wire              clk,
    input  wire              rst,
    input  wire              start,
    input  wire              abort,
    output reg               busy,
    output reg               done,      // pulse: attempt finished
    output reg  [7:0]        nsol,      // solutions emitted (saturating)
    // leaf hash unit
    output reg               hreq,
    output reg  [31:0]       hg,
    input  wire              hdone,
    input  wire [8*HOUT-1:0] hdig,
    // solution handoff: while sol_avail, the link reads xbuf[sol_raddr]
    // (registered read) and pulses sol_ack when finished
    output reg               sol_avail,
    input  wire              sol_ack,
    input  wire [K-1:0]      sol_raddr,
    output wire [RW-1:0]     sol_rdata
);
    localparam integer NB  = 1 << CB;          // sort buckets
    localparam integer VA  = $clog2(K * CAP);  // val/ptr address width
    localparam integer LW  = $clog2(K + 1);    // level counter width
    localparam integer GW  = $clog2(GMAX + 1);
    localparam integer SW  = $clog2(N + 1);    // shift amount width
    localparam integer CW  = VA + 1;           // row counters/addresses
    localparam integer GI  = $clog2(GMAX);     // group slot index
    localparam [CW-1:0] INIT_C = INIT[CW-1:0];
    localparam [CW-1:0] CAP_C  = CAP[CW-1:0];
    localparam [CW-1:0] NB_C   = NB[CW-1:0];
    localparam [K:0]    NSOL_C = NSOL[K:0];
    localparam [LW-1:0] K_C    = K[LW-1:0];
    localparam [GW-1:0] GMAX_C = GMAX[GW-1:0];
    localparam [$clog2(IPHO+1)-1:0] IPHO_C = IPHO[$clog2(IPHO+1)-1:0];
    localparam [GW-1:0] TWO_G  = {{(GW-2){1'b0}}, 2'b10};
    localparam [K:0]    TWO_K  = {{(K-1){1'b0}}, 2'b10};

    // ------------------------------------------------------------ state
    localparam [5:0]
        S_IDLE = 0, S_GEN_REQ = 1, S_GEN_WAIT = 2, S_GEN_WR = 3,
        S_RND = 4, S_CLR = 5, S_HIST0 = 6, S_HIST1 = 7, S_HIST2 = 8,
        S_PSUM0 = 9, S_PSUM1 = 10, S_SCAT0 = 11, S_SCAT1 = 12, S_SCAT2 = 13,
        S_COL0 = 14, S_COL1 = 15, S_COL2 = 16, S_PAIR0 = 17, S_PAIR = 18,
        S_PNEXT = 19, S_PDONE = 20, S_RND_END = 21,
        S_EXP_A = 22, S_EXP_B = 23, S_EXP0 = 24, S_EXP1 = 25, S_EXP2 = 26,
        S_EXP3 = 27, S_ORD0 = 28, S_ORD1 = 29, S_ORD2 = 30, S_SWP0 = 31,
        S_SWP1 = 32, S_SWP2 = 33, S_SWP3 = 34, S_ONEXT = 35, S_D0 = 36,
        S_D1 = 37, S_D2 = 38, S_EMIT = 39, S_DONE = 40;
    reg [5:0] st;

    reg [LW-1:0]  r;            // current round 1..K
    reg [CW-1:0]  cnt [0:K-1];  // rows per level
    reg [CW-1:0]  i;            // generic counter
    reg [CW-1:0]  n;            // source row count
    reg [31:0]    gidx;
    reg [$clog2(IPHO+1)-1:0] j;
    reg [8*HOUT-1:0] dig_r;
    reg [SW-1:0]  shamt;        // N - r*CB
    reg [N-1:0]   lowmask;      // shamt ones
    reg [VA-1:0]  src_base, dst_base;
    reg [CW-1:0]  run;
    reg [CB-1:0]  key_r;
    reg [RW-1:0]  row_r;
    // collision group buffer
    reg [RW-1:0]  grow [0:GMAX-1];
    reg [N-1:0]   gval [0:GMAX-1];
    reg [GW-1:0]  gcnt;
    reg [CB-1:0]  gkey;
    reg [GW-1:0]  pa, pb;
    reg           pend;         // a row that starts the next group is held
    reg [RW-1:0]  pend_row;
    reg [N-1:0]   pend_val;
    reg [CB-1:0]  pend_key;
    reg           last_grp;
    // candidate expansion / ordering / distinctness
    reg [LW-1:0]  lev;
    reg [K:0]     e, len;
    reg [RW-1:0]  p0_r, xa, xfirst;
    reg [K:0]     s, blk, t, di, dj;

    // ------------------------------------------------------- memories
    reg [N-1:0]      val_mem [0:K*CAP-1];
    reg [2*RW-1:0]   ptr_mem [0:K*CAP-1];
    reg [CW-1:0]     hist    [0:NB-1];
    reg [RW-1:0]     order   [0:CAP-1];
    reg [RW-1:0]     xbuf    [0:NSOL-1];

    reg [N-1:0]    val_q;
    reg [2*RW-1:0] ptr_q;
    reg [CW-1:0]   hist_q;
    reg [RW-1:0]   order_q;
    reg [RW-1:0]   xbuf_q;

    // memory controls, decoded from the FSM each cycle
    reg            val_we;  reg [VA-1:0] val_a;  reg [N-1:0]    val_d;
    reg            ptr_we;  reg [VA-1:0] ptr_a;  reg [2*RW-1:0] ptr_d;
    reg            hist_we; reg [CB-1:0] hist_a; reg [CW-1:0]   hist_d;
    reg            ord_we;  reg [RW-1:0] ord_a;  reg [RW-1:0]   ord_d;
    reg            x_we;    reg [K-1:0]  x_a;    reg [RW-1:0]   x_d;

    always @(posedge clk) begin
        if (val_we) val_mem[val_a] <= val_d;
        val_q <= val_mem[val_a];
        if (ptr_we) ptr_mem[ptr_a] <= ptr_d;
        ptr_q <= ptr_mem[ptr_a];
        if (hist_we) hist[hist_a] <= hist_d;
        hist_q <= hist[hist_a];
        if (ord_we) order[ord_a] <= ord_d;
        order_q <= order[ord_a];
        if (x_we) xbuf[x_a] <= x_d;
        xbuf_q <= xbuf[x_a];
    end
    assign sol_rdata = xbuf_q;

    // ------------------------------------------------ digest slicing
    // leaf j of a digest: bytes j*N/8 .. big-endian, so the first byte is
    // the most significant (matches ExpandArray bit order)
    wire [IPHO*N-1:0] slices;
    genvar gj, gt;
    generate
        for (gj = 0; gj < IPHO; gj = gj + 1) begin : g_slice
            for (gt = 0; gt < N / 8; gt = gt + 1) begin : g_byte
                assign slices[gj*N + N-1-8*gt -: 8] = dig_r[8*(gj*(N/8)+gt) +: 8];
            end
        end
    endgenerate
    wire [N-1:0] leaf_val = slices[j*N +: N];

    function [CB-1:0] key_of(input [N-1:0] v, input [SW-1:0] sh);
        reg [N-1:0] shifted;
        begin
            shifted = v >> sh;
            key_of  = shifted[CB-1:0];
        end
    endfunction

    wire [CB-1:0] val_key  = key_of(val_q, shamt);
    wire [N-1:0]  pair_x   = gval[pa[GI-1:0]] ^ gval[pb[GI-1:0]];
    wire          last_rnd = (r == K_C);
    wire [CW-1:0] cnt_r    = cnt[r[$clog2(K)-1:0]];
    wire [LW-1:0] rm1      = r - 1'b1;

    function [SW-1:0] shamt_of(input [LW-1:0] rr);  // N - rr*CB
        integer v;
        begin
            v = N - rr * CB;
            shamt_of = v[SW-1:0];
        end
    endfunction
    function [VA-1:0] base_of(input [LW-1:0] lv);   // lv*CAP
        integer v;
        begin
            v = lv * CAP;
            base_of = v[VA-1:0];
        end
    endfunction
    wire [VA-1:0] lev_base = base_of(lev);

    // ------------------------------------------ memory control decode
    always @* begin
        val_we = 0; val_a = 0; val_d = 0;
        ptr_we = 0; ptr_a = 0; ptr_d = 0;
        hist_we = 0; hist_a = 0; hist_d = 0;
        ord_we = 0; ord_a = 0; ord_d = 0;
        x_we = 0; x_a = 0; x_d = 0;
        case (st)
            S_GEN_WR: begin
                val_we = 1; val_a = i[VA-1:0]; val_d = leaf_val;
            end
            S_CLR: begin hist_we = 1; hist_a = i[CB-1:0]; hist_d = 0; end
            S_HIST0, S_SCAT0: val_a = src_base + i[VA-1:0];
            S_HIST1, S_SCAT1: hist_a = val_key;
            S_HIST2: begin hist_we = 1; hist_a = key_r; hist_d = hist_q + 1'b1; end
            S_PSUM0: hist_a = i[CB-1:0];
            S_PSUM1: begin hist_we = 1; hist_a = i[CB-1:0]; hist_d = run; end
            S_SCAT2: begin
                ord_we = 1; ord_a = hist_q[RW-1:0]; ord_d = i[RW-1:0];
                hist_we = 1; hist_a = key_r; hist_d = hist_q + 1'b1;
            end
            S_COL0: ord_a = i[RW-1:0];
            S_COL1: val_a = src_base + {{(VA-RW){1'b0}}, order_q};
            S_PAIR: if (!last_rnd && cnt_r < CAP_C) begin
                val_we = 1; val_a = dst_base + cnt_r[VA-1:0]; val_d = pair_x & lowmask;
                ptr_we = 1; ptr_a = dst_base + cnt_r[VA-1:0]; ptr_d = {grow[pa[GI-1:0]], grow[pb[GI-1:0]]};
            end
            S_EXP_A: begin x_we = 1; x_a = 0; x_d = xa; end
            S_EXP_B: begin x_we = 1; x_a = 1; x_d = row_r; end
            S_EXP0: x_a = e[K-1:0];
            S_EXP1: ptr_a = lev_base + {{(VA-RW){1'b0}}, xbuf_q};
            S_EXP2: begin x_we = 1; x_a = {e[K-2:0], 1'b1}; x_d = ptr_q[RW-1:0]; end
            S_EXP3: begin x_we = 1; x_a = {e[K-2:0], 1'b0}; x_d = p0_r; end
            S_ORD0: x_a = blk[K-1:0];
            S_ORD1: x_a = blk[K-1:0] + s[K-1:0];
            S_SWP0: x_a = blk[K-1:0] + t[K-1:0];
            S_SWP1: x_a = blk[K-1:0] + s[K-1:0] + t[K-1:0];
            S_SWP2: begin x_we = 1; x_a = blk[K-1:0] + t[K-1:0]; x_d = xbuf_q; end
            S_SWP3: begin x_we = 1; x_a = blk[K-1:0] + s[K-1:0] + t[K-1:0]; x_d = xfirst; end
            S_D0: x_a = di[K-1:0];
            S_D1: x_a = di[K-1:0] + 1'b1;
            S_D2: x_a = dj[K-1:0] + 1'b1;
            S_EMIT: x_a = sol_raddr;
            default: ;
        endcase
    end

    // ------------------------------------------------------ sequencer
    integer q;
    always @(posedge clk) begin
        done <= 1'b0;
        hreq <= 1'b0;
        if (rst || abort) begin
            st        <= S_IDLE;
            busy      <= 1'b0;
            sol_avail <= 1'b0;
        end else case (st)
        S_IDLE: if (start) begin
            busy <= 1'b1;
            nsol <= 0;
            gidx <= 0;
            i    <= 0;
            for (q = 0; q < K; q = q + 1) cnt[q] <= 0;
            st   <= S_GEN_REQ;
        end

        // ---- generate level 0: INIT leaves from ceil(INIT/IPHO) hashes
        S_GEN_REQ: begin hreq <= 1'b1; hg <= gidx; st <= S_GEN_WAIT; end
        S_GEN_WAIT: if (hdone) begin dig_r <= hdig; j <= 0; st <= S_GEN_WR; end
        S_GEN_WR: begin
            i <= i + 1'b1;
            if (i == INIT_C - 1'b1) begin
                cnt[0] <= INIT_C;
                r      <= 1;
                st     <= S_RND;
            end else if (j == IPHO_C - 1'b1) begin
                gidx <= gidx + 1;
                st   <= S_GEN_REQ;
            end else j <= j + 1'b1;
        end

        // ---- round setup
        S_RND: begin
            n        <= cnt[rm1];
            shamt    <= shamt_of(r);
            lowmask  <= ~({N{1'b1}} << shamt_of(r));
            src_base <= base_of(rm1);
            dst_base <= base_of(r);
            i        <= 0;
            st       <= S_CLR;
        end
        S_CLR: begin
            i <= i + 1'b1;
            if (i == NB_C - 1'b1) begin
                i  <= 0;
                st <= (n == 0) ? S_RND_END : S_HIST0;
            end
        end

        // ---- histogram of the next collision chunk
        S_HIST0: st <= S_HIST1;
        S_HIST1: begin key_r <= val_key; st <= S_HIST2; end
        S_HIST2: begin
            i <= i + 1'b1;
            st <= S_HIST0;
            if (i == n - 1) begin i <= 0; run <= 0; st <= S_PSUM0; end
        end

        // ---- exclusive prefix sum -> bucket start offsets
        S_PSUM0: st <= S_PSUM1;
        S_PSUM1: begin
            run <= run + hist_q;
            i   <= i + 1'b1;
            st  <= S_PSUM0;
            if (i == NB_C - 1'b1) begin i <= 0; st <= S_SCAT0; end
        end

        // ---- stable scatter into the order table
        S_SCAT0: st <= S_SCAT1;
        S_SCAT1: begin key_r <= val_key; st <= S_SCAT2; end
        S_SCAT2: begin
            i <= i + 1'b1;
            st <= S_SCAT0;
            if (i == n - 1) begin
                i        <= 0;
                gcnt     <= 0;
                pend     <= 1'b0;
                last_grp <= 1'b0;
                st       <= S_COL0;
            end
        end

        // ---- walk sorted rows, collecting runs of equal keys
        S_COL0: if (i == n) begin
            last_grp <= 1'b1;
            st       <= S_PAIR0;
        end else st <= S_COL1;
        S_COL1: begin row_r <= order_q; st <= S_COL2; end
        S_COL2: begin
            if (gcnt != 0 && val_key != gkey) begin
                pend     <= 1'b1;
                pend_row <= row_r;
                pend_val <= val_q;
                pend_key <= val_key;
                st       <= S_PAIR0;
            end else begin
                if (gcnt < GMAX_C) begin
                    grow[gcnt[GI-1:0]] <= row_r;
                    gval[gcnt[GI-1:0]] <= val_q;
                    gcnt       <= gcnt + 1'b1;
                end
                gkey <= val_key;
                i    <= i + 1'b1;
                st   <= S_COL0;
            end
        end

        // ---- all pairs of the group
        S_PAIR0: begin
            pa <= 0;
            pb <= 1;
            st <= (gcnt < 2) ? S_PDONE : S_PAIR;
        end
        S_PAIR: begin
            if (!last_rnd) begin
                if (cnt_r < CAP_C) cnt[r[$clog2(K)-1:0]] <= cnt_r + 1'b1;
                st <= S_PNEXT;
            end else if ((pair_x & lowmask) == 0) begin
                // final collision: expand this candidate
                xa    <= grow[pa[GI-1:0]];
                row_r <= grow[pb[GI-1:0]];
                st    <= S_EXP_A;
            end else st <= S_PNEXT;
        end
        S_PNEXT: begin
            st <= S_PAIR;
            if (pb == gcnt - 1'b1) begin
                if (pa == gcnt - TWO_G) st <= S_PDONE;
                else begin pa <= pa + 1'b1; pb <= pa + TWO_G; end
            end else pb <= pb + 1'b1;
        end
        S_PDONE: begin
            gcnt <= 0;
            if (pend) begin
                grow[0] <= pend_row;
                gval[0] <= pend_val;
                gkey    <= pend_key;
                gcnt    <= 1;
                pend    <= 1'b0;
                i       <= i + 1'b1;
                st      <= S_COL0;
            end else if (last_grp) st <= S_RND_END;
            else st <= S_COL0;
        end
        S_RND_END: begin
            if (last_rnd) st <= S_DONE;
            else begin r <= r + 1'b1; st <= S_RND; end
        end

        // ---- candidate: expand pointer tree into xbuf
        S_EXP_A: st <= S_EXP_B;
        S_EXP_B: begin
            lev <= K_C - 1'b1;
            len <= 2;
            e   <= 1;
            st  <= S_EXP0;
        end
        S_EXP0: st <= S_EXP1;
        S_EXP1: st <= S_EXP2;
        S_EXP2: begin p0_r <= ptr_q[2*RW-1:RW]; st <= S_EXP3; end
        S_EXP3: begin
            st <= S_EXP0;
            if (e == 0) begin
                if (lev == 1) begin
                    s  <= 1;
                    blk <= 0;
                    st <= S_ORD0;
                end else begin
                    lev <= lev - 1'b1;
                    len <= len << 1;
                    e   <= (len << 1) - 1'b1;
                end
            end else e <= e - 1'b1;
        end

        // ---- canonical order: bottom-up, swap halves whose right side
        //      starts with the smaller index
        S_ORD0: st <= S_ORD1;
        S_ORD1: begin xfirst <= xbuf_q; st <= S_ORD2; end
        S_ORD2: begin
            if (xbuf_q < xfirst) begin t <= 0; st <= S_SWP0; end
            else st <= S_ONEXT;
        end
        S_SWP0: st <= S_SWP1;
        S_SWP1: begin xfirst <= xbuf_q; st <= S_SWP2; end
        S_SWP2: st <= S_SWP3;
        S_SWP3: begin
            if (t == s - 1'b1) st <= S_ONEXT;
            else begin t <= t + 1'b1; st <= S_SWP0; end
        end
        S_ONEXT: begin
            st <= S_ORD0;
            if (blk + (s << 1) >= NSOL_C) begin
                blk <= 0;
                s   <= s << 1;
                if ((s << 1) == NSOL_C) begin di <= 0; st <= S_D0; end
            end else blk <= blk + (s << 1);
        end

        // ---- reject repeated indices (all pairs)
        S_D0: st <= S_D1;
        S_D1: begin xfirst <= xbuf_q; dj <= di + 1'b1; st <= S_D2; end
        S_D2: begin
            if (xbuf_q == xfirst) st <= S_PNEXT;          // duplicate
            else if (dj == NSOL_C - 1'b1) begin
                if (di == NSOL_C - TWO_K) begin
                    sol_avail <= 1'b1;
                    st        <= S_EMIT;
                end else begin di <= di + 1'b1; st <= S_D0; end
            end else dj <= dj + 1'b1;
        end
        S_EMIT: if (sol_ack) begin
            sol_avail <= 1'b0;
            if (nsol != 8'hFF) nsol <= nsol + 1'b1;
            st <= S_PNEXT;
        end

        S_DONE: begin busy <= 1'b0; done <= 1'b1; st <= S_IDLE; end
        default: st <= S_IDLE;
        endcase
    end
endmodule

`default_nettype wire
