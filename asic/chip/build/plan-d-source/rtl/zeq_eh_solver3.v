// Equihash (N,K) solver, streaming edition.
//
// Same algorithm, same outputs and same emission order as zeq_eh_solver /
// zeq_eh_solver2 (model/equihash_ref.py:hw_solve), restructured so memory
// latency is hidden instead of paid on every access:
//
//   * VAL and ORD reads are streamed: up to D requests in flight per port,
//     responses land in small FIFOs, and credits (in flight + buffered <= D)
//     guarantee a response always has room (ports cannot be backpressured).
//   * No histogram pass. A row's next-round collision key is known the
//     moment the row is created (leaf hashing for round 1, pairing for
//     later rounds), so the histogram for round r+1 is accumulated while
//     round r writes its rows. Two on-chip banks (2^CB x CW bits each,
//     2.9 MB at 200,9) alternate: one feeds this round's prefix sum and
//     scatter, the other collects next round's counts. Each bank is cleared
//     in the background while the other is in use. This removes a full
//     read of every level (~25% of VAL traffic at 200,9).
//   * SCAT consumes one row every 2 cycles (on-chip read-modify-write)
//     while the VAL stream runs ahead.
//   * COL walks the sorted order as a pipeline: ORD stream -> VAL stream ->
//     group assembler -> pair generator.
//   * Leaf hashing overlaps the level-0 writes of the previous digest.
//
// Candidate expansion walks the pointer tree to 2^K leaves, orders them
// and rejects repeats, as in solver2, with one addition: after each of the
// first two expansion levels (4 and 8 rows) the rows are checked for a
// repeat. At 200,9 about 99.9% of final-round candidates are degenerate
// trees that already repeat a row there, so the 2^K-pointer walk is skipped
// for them. The output is unchanged (a repeated row means repeated leaves).
//
// Cancel: reads still in flight are counted and their responses dropped
// before a new attempt starts, so a later attempt never sees stale data.
`default_nettype none

module zeq_eh_solver3 #(
    parameter integer N    = 48,
    parameter integer K    = 5,
    parameter integer GMAX = 16,  // rows kept per collision group (see README: yield)
    parameter integer D    = 8,   // stream depth (reads in flight per port)
    // derived (do not override)
    parameter integer CB   = N / (K + 1),
    parameter integer INIT = 1 << (CB + 1),
    parameter integer IPHO = 512 / N,
    parameter integer HOUT = IPHO * N / 8,
    parameter integer CAP  = 2 * INIT,
    parameter integer RW   = CB + 2,
    parameter integer NSOL = 1 << K,
    parameter integer CW   = CB + 3,
    parameter integer VVA  = CB + 3,
    parameter integer PVA  = $clog2((K - 1) * CAP)
) (
    input  wire              clk,
    input  wire              rst,
    input  wire              start,
    input  wire              cancel,
    output reg               busy,
    output reg               done,
    output reg  [7:0]        nsol,
    output reg               hreq,
    output reg  [31:0]       hg,
    input  wire              hdone,
    input  wire [8*HOUT-1:0] hdig,
    output reg               sol_avail,
    input  wire              sol_ack,
    input  wire [K-1:0]      sol_raddr,
    output wire [RW-1:0]     sol_rdata,
    output reg               val_req_valid,
    input  wire              val_req_ready,
    output reg               val_req_we,
    output reg  [VVA-1:0]    val_req_addr,
    output reg  [N-1:0]      val_req_wdata,
    input  wire              val_rsp_valid,
    input  wire [N-1:0]      val_rsp_rdata,
    output reg               ptr_req_valid,
    input  wire              ptr_req_ready,
    output reg               ptr_req_we,
    output reg  [PVA-1:0]    ptr_req_addr,
    output reg  [2*RW-1:0]   ptr_req_wdata,
    input  wire              ptr_rsp_valid,
    input  wire [2*RW-1:0]   ptr_rsp_rdata,
    output reg               ord_req_valid,
    input  wire              ord_req_ready,
    output reg               ord_req_we,
    output reg  [RW-1:0]     ord_req_addr,
    output reg  [RW-1:0]     ord_req_wdata,
    input  wire              ord_rsp_valid,
    input  wire [RW-1:0]     ord_rsp_rdata
);
    localparam integer NB = 1 << CB;
    localparam integer LW = $clog2(K + 1);
    localparam integer GW = $clog2(GMAX + 1);
    localparam integer GI = $clog2(GMAX);
    localparam integer SW = $clog2(N + 1);
    localparam integer DW = $clog2(D) + 1;
    localparam integer JW = $clog2(IPHO + 1);
    localparam [CW-1:0] INIT_C = INIT[CW-1:0];
    localparam [CW-1:0] CAP_C  = CAP[CW-1:0];
    localparam [CW-1:0] NB_C   = NB[CW-1:0];
    localparam [K:0]    NSOL_C = NSOL[K:0];
    localparam [LW-1:0] K_C    = K[LW-1:0];
    localparam [GW-1:0] GMAX_C = GMAX[GW-1:0];
    localparam [JW-1:0] IPHO_C = IPHO[JW-1:0];
    localparam [DW-1:0] D_C    = D[DW-1:0];
    localparam [GW-1:0] TWO_G  = {{(GW-2){1'b0}}, 2'b10};
    localparam [K:0]    TWO_K  = {{(K-1){1'b0}}, 2'b10};
    localparam [31:0]   NGRP   = (INIT + IPHO - 1) / IPHO;

    // ------------------------------------------------------------ phases
    localparam [3:0] P_IDLE = 0, P_DRAIN = 1, P_GEN = 2, P_RND = 3, P_CLR = 4,
                     P_PSUM = 6, P_SCAT = 7, P_COL = 8, P_REND = 9,
                     P_CAND = 10, P_DONE = 11;
    reg [3:0] ph;

    reg [LW-1:0]  r;
    reg [CW-1:0]  cnt [0:K-1];
    reg [CW-1:0]  n;            // rows in the source level
    reg [SW-1:0]  shamt;
    reg [N-1:0]   lowmask;
    reg           src_bank;
    wire          last_rnd = (r == K_C);
    wire [CW-1:0] cnt_r    = cnt[r[$clog2(K)-1:0]];
    wire [LW-1:0] rm1      = r - 1'b1;

    function [CB-1:0] key_of(input [N-1:0] v, input [SW-1:0] sh);
        reg [N-1:0] shifted;
        begin
            shifted = v >> sh;
            key_of  = shifted[CB-1:0];
        end
    endfunction
    function [SW-1:0] shamt_of(input [LW-1:0] rr);
        integer v;
        begin
            v = N - rr * CB;
            shamt_of = v[SW-1:0];
        end
    endfunction
    function [PVA-1:0] pbase_of(input [LW-1:0] lv);   // (lv-1)*CAP
        integer v;
        begin
            v = ({{(32-LW){1'b0}}, lv} - 1) * CAP;
            pbase_of = v[PVA-1:0];
        end
    endfunction

    // --------------------------------------------------- on-chip tables
    // two single-port banks; "cur" (bank hb) holds this round's counts,
    // "oth" collects next round's (or is being cleared)
    reg [CW-1:0] hist0 [0:NB-1];
    reg [CW-1:0] hist1 [0:NB-1];
    reg          hb;
    reg          hist_rd, hist_we, oth_rd, oth_we;   // cur / oth controls
    reg [CB-1:0] hist_a, oth_a;
    reg [CW-1:0] hist_d, oth_d;
    reg [CW-1:0] hq0, hq1;
    wire [CW-1:0] hist_q = hb ? hq1 : hq0;
    wire [CW-1:0] oth_q  = hb ? hq0 : hq1;
    wire         b0_rd = hb ? oth_rd : hist_rd,  b1_rd = hb ? hist_rd : oth_rd;
    wire         b0_we = hb ? oth_we : hist_we,  b1_we = hb ? hist_we : oth_we;
    wire [CB-1:0] b0_a = hb ? oth_a : hist_a,    b1_a = hb ? hist_a : oth_a;
    wire [CW-1:0] b0_d = hb ? oth_d : hist_d,    b1_d = hb ? hist_d : oth_d;
    always @(posedge clk) begin
        if (b0_we) hist0[b0_a] <= b0_d;
        if (b0_rd) hq0 <= hist0[b0_a];
        if (b1_we) hist1[b1_a] <= b1_d;
        if (b1_rd) hq1 <= hist1[b1_a];
    end

    reg [RW-1:0] xbuf [0:NSOL-1];
    reg          x_rd, x_we;
    reg [K-1:0]  x_a;
    reg [RW-1:0] x_d, xbuf_q;
    always @(posedge clk) begin
        if (x_we) xbuf[x_a] <= x_d;
        if (x_rd) xbuf_q <= xbuf[x_a];
    end
    assign sol_rdata = xbuf_q;

    // ---------------------------------------------------------- streams
    // VAL responses (rows of the source level) and, in COL, the row ids
    // issued alongside them; ORD responses (sorted row ids) in COL.
    reg           fifo_clr;
    wire          fv_empty, fr_empty, fo_empty;
    wire [DW-1:0] fv_cnt, fr_cnt, fo_cnt;
    wire [N-1:0]  fv_head;
    wire [RW-1:0] fr_head, fo_head;
    reg           fv_pop, fr_push, fr_pop, fo_pop;
    reg [RW-1:0]  fr_din;
    reg  [DW-1:0] v_out, o_out;         // reads in flight
    reg           p_out;                // pointer read in flight
    reg           draining;             // drop responses of a cancelled run

    wire v_rsp = val_rsp_valid & ~draining;
    wire o_rsp = ord_rsp_valid & ~draining;

    zeq_sfifo #(.W(N), .D(D)) u_fv (
        .clk(clk), .clr(fifo_clr), .push(v_rsp), .din(val_rsp_rdata),
        .pop(fv_pop), .dout(fv_head), .empty(fv_empty), .count(fv_cnt));
    zeq_sfifo #(.W(RW), .D(D)) u_fr (
        .clk(clk), .clr(fifo_clr), .push(fr_push), .din(fr_din),
        .pop(fr_pop), .dout(fr_head), .empty(fr_empty), .count(fr_cnt));
    zeq_sfifo #(.W(RW), .D(D)) u_fo (
        .clk(clk), .clr(fifo_clr), .push(o_rsp), .din(ord_rsp_rdata),
        .pop(fo_pop), .dout(fo_head), .empty(fo_empty), .count(fo_cnt));

    wire v_credit = (v_out + fv_cnt) < D_C;
    wire o_credit = (o_out + fo_cnt) < D_C;

    wire v_fire = val_req_valid & val_req_ready;
    wire o_fire = ord_req_valid & ord_req_ready;
    wire p_fire = ptr_req_valid & ptr_req_ready;

    always @(posedge clk) begin
        if (rst) begin
            v_out <= 0;
            o_out <= 0;
            p_out <= 1'b0;
        end else begin
            v_out <= v_out + {{(DW-1){1'b0}}, v_fire & ~val_req_we}
                           - {{(DW-1){1'b0}}, val_rsp_valid};
            o_out <= o_out + {{(DW-1){1'b0}}, o_fire & ~ord_req_we}
                           - {{(DW-1){1'b0}}, ord_rsp_valid};
            if (p_fire & ~ptr_req_we) p_out <= 1'b1;
            else if (ptr_rsp_valid) p_out <= 1'b0;
        end
    end

    // ------------------------------------------------------- work state
    // GEN
    reg [31:0]       gidx;           // next hash group to request
    reg              hash_busy;      // a leaf hash is being computed
    reg              dig_rdy;        // it finished; hdig is stable until reused
    reg              have_dig;
    reg [8*HOUT-1:0] dig_r;
    reg [JW-1:0]     j;
    reg [CW-1:0]     wi;             // leaves written
    // streaming counters
    reg [CW-1:0]     rd_i;           // VAL reads issued (HIST/SCAT)
    reg [CW-1:0]     oi;             // ORD reads issued (COL)
    reg [CW-1:0]     used;           // rows consumed
    reg              hs;             // RMW half (SCAT/PSUM)
    reg              gen_rmw;        // level-0 histogram update in progress
    reg [CB-1:0]     gen_key;
    reg              acc_pend;       // next-round histogram update (COL)
    reg [CB-1:0]     acc_key;
    reg [CW-1:0]     bclr_i;         // background clear of the oth bank
    reg [CB-1:0]     key_r;
    reg [CW-1:0]     run;
    reg [CW-1:0]     bi;             // bucket index (CLR/PSUM)
    // COL assembler / pair generator
    localparam [2:0] C_COLLECT = 0, C_PAIR0 = 1, C_PAIR = 2, C_PNEXT = 3, C_PDONE = 4;
    reg [2:0]        cs;
    reg [RW-1:0]     grow [0:GMAX-1];
    reg [N-1:0]      gval [0:GMAX-1];
    reg [GW-1:0]     gcnt, pa, pb;
    reg [CB-1:0]     gkey;
    reg              pv_done, pp_done;  // pair writes accepted
    wire [N-1:0]     pair_x = gval[pa[GI-1:0]] ^ gval[pb[GI-1:0]];
    wire [CB-1:0]    head_key = key_of(fv_head, shamt);
    wire [SW-1:0]    shamt_nx = shamt - CB[SW-1:0];          // next round
    wire [CB-1:0]    next_key = key_of(pair_x & lowmask, shamt_nx);
    wire [CB-1:0]    leaf_key = key_of(leaf_val, shamt_of(1));
    wire             pair_store = !last_rnd && (cnt_r < CAP_C);
    // candidate expansion (as solver2)
    localparam [4:0] X_A = 0, X_B = 1, X_E0 = 2, X_E1 = 3, X_E1W = 4, X_E2 = 5,
                     X_E3 = 6, X_O0 = 7, X_O1 = 8, X_O2 = 9, X_S0 = 10, X_S1 = 11,
                     X_S2 = 12, X_S3 = 13, X_ON = 14, X_D0 = 15, X_D1 = 16,
                     X_D2 = 17, X_EMIT = 18;
    reg [4:0]        xs;
    reg [LW-1:0]     lev;
    reg [K:0]        e, len, s, blk, t, di, dj;
    reg [K:0]        dlim;           // entries covered by the repeat check
    reg              early;          // repeat check mid-expansion
    reg [RW-1:0]     xa, xb, xfirst, p0_r;
    reg [2*RW-1:0]   ptr_q;

    // ------------------------------------------------- digest slicing
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

    // --------------------------------------------- request generation
    // What each port is asked to do this cycle, from the current state.
    wire hist_stream = (ph == P_SCAT);
    wire col_stream  = (ph == P_COL) || (ph == P_CAND);
    wire pair_wr     = (ph == P_COL) && (cs == C_PAIR) && pair_store;
    always @* begin
        val_req_valid = 1'b0; val_req_we = 1'b0; val_req_addr = 0; val_req_wdata = 0;
        ord_req_valid = 1'b0; ord_req_we = 1'b0; ord_req_addr = 0; ord_req_wdata = 0;
        ptr_req_valid = 1'b0; ptr_req_we = 1'b0; ptr_req_addr = 0; ptr_req_wdata = 0;
        fr_push = 1'b0; fr_din = 0; fo_pop = 1'b0;
        // VAL port
        if (ph == P_GEN && have_dig && !gen_rmw) begin
            val_req_valid = 1'b1; val_req_we = 1'b1;
            val_req_addr  = {1'b0, wi[VVA-2:0]};
            val_req_wdata = leaf_val;
        end else if (hist_stream && rd_i != n && v_credit) begin
            val_req_valid = 1'b1;
            val_req_addr  = {src_bank, rd_i[VVA-2:0]};
        end else if (pair_wr && !pv_done) begin
            val_req_valid = 1'b1; val_req_we = 1'b1;
            val_req_addr  = {~src_bank, cnt_r[VVA-2:0]};
            val_req_wdata = pair_x & lowmask;
        end else if (col_stream && !fo_empty && v_credit) begin
            val_req_valid = 1'b1;
            val_req_addr  = {src_bank, {(VVA-1-RW){1'b0}}, fo_head};
            fo_pop  = val_req_ready;
            fr_push = val_req_ready;
            fr_din  = fo_head;
        end
        // ORD port
        if (ph == P_SCAT && hs) begin
            ord_req_valid = 1'b1; ord_req_we = 1'b1;
            ord_req_addr  = hist_q[RW-1:0];
            ord_req_wdata = used[RW-1:0];
        end else if (col_stream && oi != n && o_credit) begin
            ord_req_valid = 1'b1;
            ord_req_addr  = oi[RW-1:0];
        end
        // PTR port
        if (pair_wr && !pp_done) begin
            ptr_req_valid = 1'b1; ptr_req_we = 1'b1;
            ptr_req_addr  = pbase_of(r) + {{(PVA-CW){1'b0}}, cnt_r};
            ptr_req_wdata = {grow[pa[GI-1:0]], grow[pb[GI-1:0]]};
        end else if (ph == P_CAND && xs == X_E1) begin
            ptr_req_valid = 1'b1;
            ptr_req_addr  = pbase_of(lev) + {{(PVA-RW){1'b0}}, xbuf_q};
        end
    end

    // on-chip memory controls
    always @* begin
        hist_rd = 1'b0; hist_we = 1'b0; hist_a = 0; hist_d = 0;
        oth_rd  = 1'b0; oth_we  = 1'b0; oth_a  = 0; oth_d  = 0;
        x_rd = 1'b0; x_we = 1'b0; x_a = 0; x_d = 0;
        case (ph)
            P_CLR: begin hist_we = 1'b1; hist_a = bi[CB-1:0]; end
            // round-1 counts: read as a leaf is written (its increment
            // lands the next cycle, below, even if GEN has just ended)
            P_GEN: if (have_dig && !gen_rmw) begin
                hist_rd = 1'b1; hist_a = leaf_key;
            end
            P_SCAT: if (!hs) begin
                hist_rd = !fv_empty; hist_a = head_key;
            end else begin
                hist_we = 1'b1; hist_a = key_r; hist_d = hist_q + 1'b1;
            end
            P_PSUM: if (!hs) begin
                hist_rd = 1'b1; hist_a = bi[CB-1:0];
            end else begin
                hist_we = 1'b1; hist_a = bi[CB-1:0]; hist_d = run;
            end
            default: ;
        endcase
        if (gen_rmw) begin
            hist_we = 1'b1; hist_a = gen_key; hist_d = hist_q + 1'b1;
        end
        // oth bank: cleared during PSUM/SCAT, then collects next round's
        // counts as COL creates rows
        if ((ph == P_PSUM || ph == P_SCAT) && bclr_i != NB_C) begin
            oth_we = 1'b1; oth_a = bclr_i[CB-1:0];
        end
        if (ph == P_COL && cs == C_PAIR && pair_store) begin
            oth_rd = 1'b1; oth_a = next_key;
        end
        if (ph == P_COL && cs == C_PNEXT && acc_pend) begin
            oth_we = 1'b1; oth_a = acc_key; oth_d = oth_q + 1'b1;
        end
        if (ph == P_CAND) case (xs)
            X_A:  begin x_we = 1'b1; x_a = 0; x_d = xa; end
            X_B:  begin x_we = 1'b1; x_a = 1; x_d = xb; end
            X_E0: begin x_rd = 1'b1; x_a = e[K-1:0]; end
            X_E2: begin x_we = 1'b1; x_a = {e[K-2:0], 1'b1}; x_d = ptr_q[RW-1:0]; end
            X_E3: begin x_we = 1'b1; x_a = {e[K-2:0], 1'b0}; x_d = p0_r; end
            X_O0: begin x_rd = 1'b1; x_a = blk[K-1:0]; end
            X_O1: begin x_rd = 1'b1; x_a = blk[K-1:0] + s[K-1:0]; end
            X_S0: begin x_rd = 1'b1; x_a = blk[K-1:0] + t[K-1:0]; end
            X_S1: begin x_rd = 1'b1; x_a = blk[K-1:0] + s[K-1:0] + t[K-1:0]; end
            X_S2: begin x_we = 1'b1; x_a = blk[K-1:0] + t[K-1:0]; x_d = xbuf_q; end
            X_S3: begin x_we = 1'b1; x_a = blk[K-1:0] + s[K-1:0] + t[K-1:0]; x_d = xfirst; end
            X_D0: begin x_rd = 1'b1; x_a = di[K-1:0]; end
            X_D1: begin x_rd = 1'b1; x_a = di[K-1:0] + 1'b1; end
            X_D2: begin x_rd = 1'b1; x_a = dj[K-1:0] + 1'b1; end
            X_EMIT: begin x_rd = 1'b1; x_a = sol_raddr; end
            default: ;
        endcase
    end

    // stream consumers pop in the sequential block's decisions
    always @* begin
        fv_pop = 1'b0;
        fr_pop = 1'b0;
        if (ph == P_SCAT && !hs && !fv_empty) fv_pop = 1'b1;
        if (ph == P_COL && cs == C_COLLECT && used != n && !fv_empty && !fr_empty
            && !(gcnt != 0 && head_key != gkey)) begin
            fv_pop = 1'b1;
            fr_pop = 1'b1;
        end
    end

    // -------------------------------------------------------- sequencer
    integer q;
    always @(posedge clk) begin
        done     <= 1'b0;
        hreq     <= 1'b0;
        fifo_clr <= 1'b0;
        if (rst) begin
            ph        <= P_IDLE;
            busy      <= 1'b0;
            sol_avail <= 1'b0;
            draining  <= 1'b0;
            hash_busy <= 1'b0;
        end else if (cancel) begin
            ph        <= P_IDLE;
            busy      <= 1'b0;
            sol_avail <= 1'b0;
            hash_busy <= 1'b0;
            draining  <= 1'b1;          // until in-flight reads return
            fifo_clr  <= 1'b1;
        end else begin
            if (draining && v_out == 0 && o_out == 0 && !p_out) draining <= 1'b0;
            if ((ph == P_PSUM || ph == P_SCAT) && bclr_i != NB_C) bclr_i <= bclr_i + 1'b1;

            case (ph)
            P_IDLE: if (start) begin
                busy <= 1'b1;
                nsol <= 0;
                for (q = 0; q < K; q = q + 1) cnt[q] <= 0;
                ph   <= P_DRAIN;
            end
            P_DRAIN: if (!draining) begin
                fifo_clr  <= 1'b1;
                wi        <= 0;
                have_dig  <= 1'b0;
                dig_rdy   <= 1'b0;
                gen_rmw   <= 1'b0;
                hb        <= 1'b0;
                bi        <= 0;
                r         <= 1;             // shamt_of(1) keys the leaves
                hreq      <= 1'b1;          // first leaf hash (runs during CLR)
                hg        <= 0;
                gidx      <= 1;
                hash_busy <= 1'b1;
                ph        <= P_CLR;
            end
            // bank 0 must be zero before leaves are counted into it
            P_CLR: begin
                if (hash_busy && hdone) begin hash_busy <= 1'b0; dig_rdy <= 1'b1; end
                bi <= bi + 1'b1;
                if (bi == NB_C - 1'b1) ph <= P_GEN;
            end

            // ---- level 0: hash groups, overlapping the next hash with
            //      the writes of the current digest
            P_GEN: begin
                // hdone is a pulse; remember it until the previous digest
                // has been written out (backpressure can make that slow)
                if (hash_busy && hdone) begin
                    hash_busy <= 1'b0;
                    dig_rdy   <= 1'b1;
                end
                if ((dig_rdy || (hash_busy && hdone)) && !have_dig) begin
                    dig_r    <= hdig;
                    j        <= 0;
                    have_dig <= 1'b1;
                    dig_rdy  <= 1'b0;
                    if (gidx < NGRP) begin       // start the next hash now
                        hreq      <= 1'b1;
                        hg        <= gidx;
                        gidx      <= gidx + 1;
                        hash_busy <= 1'b1;
                    end
                end
                if (gen_rmw) gen_rmw <= 1'b0;
                if (have_dig && v_fire) begin
                    gen_rmw <= 1'b1;             // count this leaf next cycle
                    gen_key <= leaf_key;
                    wi <= wi + 1'b1;
                    j  <= j + 1'b1;
                    if (wi == INIT_C - 1'b1) begin
                        have_dig <= 1'b0;
                        cnt[0]   <= INIT_C;
                        ph       <= P_RND;    // the last count lands in P_RND
                    end else if (j == IPHO_C - 1'b1) have_dig <= 1'b0;
                end
            end

            // ---- round setup
            P_RND: begin
                gen_rmw  <= 1'b0;
                n        <= cnt[rm1];
                shamt    <= shamt_of(r);
                lowmask  <= ~({N{1'b1}} << shamt_of(r));
                src_bank <= rm1[0];
                rd_i     <= 0;
                used     <= 0;
                hs       <= 1'b0;
                bi       <= 0;
                run      <= 0;
                bclr_i   <= 0;
                fifo_clr <= 1'b1;
                ph       <= P_PSUM;
            end

            // ---- exclusive prefix sum
            P_PSUM: begin
                hs <= ~hs;
                if (hs) begin
                    run <= run + hist_q;
                    bi  <= bi + 1'b1;
                    if (bi == NB_C - 1'b1) begin
                        rd_i     <= 0;
                        used     <= 0;
                        hs       <= 1'b0;
                        fifo_clr <= 1'b1;
                        ph       <= P_SCAT;
                    end
                end
            end

            // ---- stable scatter: ord[hist[key]++] = row
            P_SCAT: begin
                if (v_fire) rd_i <= rd_i + 1'b1;
                if (used == n) begin
                    if (bclr_i == NB_C) begin   // oth bank ready to collect
                        oi       <= 0;
                        used     <= 0;
                        gcnt     <= 0;
                        acc_pend <= 1'b0;
                        cs       <= C_COLLECT;
                        fifo_clr <= 1'b1;
                        ph       <= P_COL;
                    end
                end else if (!hs) begin
                    if (!fv_empty) begin key_r <= head_key; hs <= 1'b1; end
                end else if (o_fire) begin
                    used <= used + 1'b1;
                    hs   <= 1'b0;
                end
            end

            // ---- sorted walk: group assembler + pair generator
            P_COL: begin
                if (o_fire && !ord_req_we) oi <= oi + 1'b1;
                case (cs)
                C_COLLECT: begin
                    if (used == n) cs <= C_PAIR0;               // last group
                    else if (!fv_empty && !fr_empty) begin
                        if (gcnt != 0 && head_key != gkey) cs <= C_PAIR0;
                        else begin
                            if (gcnt < GMAX_C) begin
                                grow[gcnt[GI-1:0]] <= fr_head;
                                gval[gcnt[GI-1:0]] <= fv_head;
                                gcnt <= gcnt + 1'b1;
                            end
                            gkey <= head_key;
                            used <= used + 1'b1;
                        end
                    end
                end
                C_PAIR0: begin
                    pa      <= 0;
                    pb      <= 1;
                    pv_done <= 1'b0;
                    pp_done <= 1'b0;
                    cs      <= (gcnt < 2) ? C_PDONE : C_PAIR;
                end
                C_PAIR: begin
                    if (!last_rnd) begin
                        if (!pair_store) cs <= C_PNEXT;
                        else begin
                            if (v_fire && val_req_we) pv_done <= 1'b1;
                            if (p_fire && ptr_req_we) pp_done <= 1'b1;
                            if ((pv_done || (v_fire && val_req_we)) &&
                                (pp_done || (p_fire && ptr_req_we))) begin
                                cnt[r[$clog2(K)-1:0]] <= cnt_r + 1'b1;
                                acc_pend <= 1'b1;       // count it for next round
                                acc_key  <= next_key;
                                cs <= C_PNEXT;
                            end
                        end
                    end else if ((pair_x & lowmask) == 0) begin
                        xa <= grow[pa[GI-1:0]];
                        xb <= grow[pb[GI-1:0]];
                        xs <= X_A;
                        ph <= P_CAND;
                    end else cs <= C_PNEXT;
                end
                C_PNEXT: begin
                    pv_done  <= 1'b0;
                    pp_done  <= 1'b0;
                    acc_pend <= 1'b0;
                    cs <= C_PAIR;
                    if (pb == gcnt - 1'b1) begin
                        if (pa == gcnt - TWO_G) cs <= C_PDONE;
                        else begin pa <= pa + 1'b1; pb <= pa + TWO_G; end
                    end else pb <= pb + 1'b1;
                end
                default: begin   // C_PDONE
                    gcnt <= 0;
                    cs   <= C_COLLECT;
                    if (used == n) ph <= P_REND;
                end
                endcase
            end

            P_REND: begin
                if (last_rnd) ph <= P_DONE;
                else begin
                    r  <= r + 1'b1;
                    hb <= ~hb;           // next round's counts are in oth
                    ph <= P_RND;
                end
            end

            // ---- candidate: expand, order, check, emit (as solver2)
            P_CAND: begin
                if (o_fire && !ord_req_we) oi <= oi + 1'b1;
                case (xs)
                X_A: xs <= X_B;
                X_B: begin lev <= K_C - 1'b1; len <= 2; e <= 1; early <= 1'b0; xs <= X_E0; end
                X_E0: xs <= X_E1;
                X_E1: if (p_fire) xs <= X_E1W;
                X_E1W: if (ptr_rsp_valid) begin ptr_q <= ptr_rsp_rdata; xs <= X_E2; end
                X_E2: begin p0_r <= ptr_q[2*RW-1:RW]; xs <= X_E3; end
                X_E3: begin
                    xs <= X_E0;
                    if (e == 0) begin
                        if (lev == 1) begin s <= 1; blk <= 0; xs <= X_O0; end
                        else begin
                            lev <= lev - 1'b1;
                            len <= len << 1;
                            e   <= (len << 1) - 1'b1;
                            // 4 or 8 rows now: cheap early repeat check
                            if ((len << 1) <= 8) begin
                                dlim  <= len << 1;
                                di    <= 0;
                                early <= 1'b1;
                                xs    <= X_D0;
                            end
                        end
                    end else e <= e - 1'b1;
                end
                X_O0: xs <= X_O1;
                X_O1: begin xfirst <= xbuf_q; xs <= X_O2; end
                X_O2: if (xbuf_q < xfirst) begin t <= 0; xs <= X_S0; end
                      else xs <= X_ON;
                X_S0: xs <= X_S1;
                X_S1: begin xfirst <= xbuf_q; xs <= X_S2; end
                X_S2: xs <= X_S3;
                X_S3: if (t == s - 1'b1) xs <= X_ON;
                      else begin t <= t + 1'b1; xs <= X_S0; end
                X_ON: begin
                    xs <= X_O0;
                    if (blk + (s << 1) >= NSOL_C) begin
                        blk <= 0;
                        s   <= s << 1;
                        if ((s << 1) == NSOL_C) begin di <= 0; dlim <= NSOL_C; xs <= X_D0; end
                    end else blk <= blk + (s << 1);
                end
                X_D0: xs <= X_D1;
                X_D1: begin xfirst <= xbuf_q; dj <= di + 1'b1; xs <= X_D2; end
                X_D2: begin
                    if (xbuf_q == xfirst) begin        // repeat: drop candidate
                        ph <= P_COL; cs <= C_PNEXT;
                    end else if (dj == dlim - 1'b1) begin
                        if (di == dlim - TWO_K) begin
                            if (early) begin           // no repeat yet: expand on
                                early <= 1'b0;
                                xs    <= X_E0;
                            end else begin
                                sol_avail <= 1'b1;
                                xs        <= X_EMIT;
                            end
                        end else begin di <= di + 1'b1; xs <= X_D0; end
                    end else dj <= dj + 1'b1;
                end
                default: if (sol_ack) begin            // X_EMIT
                    sol_avail <= 1'b0;
                    if (nsol != 8'hFF) nsol <= nsol + 1'b1;
                    ph <= P_COL;
                    cs <= C_PNEXT;
                end
                endcase
            end

            P_DONE: begin busy <= 1'b0; done <= 1'b1; ph <= P_IDLE; end
            default: ph <= P_IDLE;
            endcase
        end
    end
endmodule

`default_nettype wire
