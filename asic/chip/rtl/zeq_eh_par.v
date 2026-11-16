// Equihash (N,K) solver, bucket-parallel edition (ZEQ-200X architecture).
//
// Rows of each level live in 2^BB buckets, chosen by the top BB bits of
// the row's *next* collision key; bucket d is stored in bank d % P, at
// most S = SLOTS <= 2^SB slots per bucket. P engines each own one bank and process
// its buckets one at a time:
//   LOAD  read the bucket's rows, histogram the remaining LB = CB-BB key bits
//   PSUM  prefix sum -> group offsets        SCAT  stable scatter of slots
//   WALK  walk groups (first GMAX rows each), XOR every pair, and send the
//         new row to the bank of its next bucket through a P x P crossbar
//         (one write per bank per cycle, round-robin grant)
// Parents of a row are in one source bucket, so the stored pointer is
// (bucket, slot a, slot b), BB + 2*SB bits; level-0 slots store the leaf
// index. Leaf hashing is striped over HP = 2^HPB <= P Blake2b units
// (engine p < HP hashes groups p, p+HP, ...), feeding the same crossbar,
// which delivers each leaf to its bucket's bank whichever engine hashed it. Histograms carry a
// sequence tag instead of being cleared per bucket.
//
// In the last round, pairs whose remaining bits are all zero go to one
// shared expansion unit: it walks the pointer tree across banks to 2^K
// leaf indices (rejecting repeated rows after 4 and 8 entries), puts them
// in zcash canonical order, checks for repeats and emits the solution.
//
// Slot order inside a bucket depends on crossbar arbitration, so which
// rows a full bucket drops can differ from the sequential model; with
// caps that never bind, the solution *set* equals model/par_model.py.
`default_nettype none

module zeq_eh_par #(
    parameter integer N    = 48,
    parameter integer K    = 5,
    parameter integer BB   = 4,    // bucket bits
    parameter integer PB   = 2,    // log2 engines
    parameter integer SB   = 6,    // log2 slots per bucket
    parameter integer SLOTS = 1 << SB, // physical capacity, need not be a power of two
    parameter integer GMAX = 16,
    parameter integer GROUP_REPLAY = 0, // exact bounded-buffer group enumeration
    parameter integer STAGED_NETWORK = 0, // buffered two-stage row transport
    parameter integer PACKED_TABLES = 0, // lifetime reuse of value slices for parents
    parameter integer SPLIT_KEYS = 0, // narrow key RAM avoids value reads in scatter
    parameter integer COMPACT_VALUES = 0, // omit first collision chunk from row payload
    parameter integer SPLIT = 1,   // Blake2b G steps per cycle
    parameter integer HPB  = PB,   // log2 leaf-hash units (<= PB); a test
                                   // chip needs one, a miner one per engine
    parameter integer BUCKET0_SLOTS = SLOTS, // optional extra capacity only in bucket zero
    parameter integer DROP_ZERO = 0, // discard intermediate rows whose remaining bits are all zero
    parameter integer LEAF_SET = 0, // linear-time distinct-leaf check (hash set) instead of pairwise compare
    parameter integer EMIT = 1, // pair emitters per engine: 2 pairs a second finished group in its buffer (needs GBUF=3, STAGED_NETWORK=2)
    parameter integer QDEPTH = 4, // rows queued per bank with STAGED_NETWORK = 2 (power of two)
    parameter integer GBUF = 2, // group buffers per engine: 2, or 3 (one finished group may wait while another pairs)
    parameter integer CHAIN = 0, // write-time key chains replace the counting sort (no PS/SC pass)
    parameter integer HASH_UNITS = 1, // Blake2b units per hashing engine (leaf hashing is hash-bound at 1)
    // derived (do not override)
    parameter integer CB   = N / (K + 1),
    parameter integer RW   = CB + 2,
    parameter integer NSOL = 1 << K
) (
    input  wire          clk,
    input  wire          rst,
    input  wire [1119:0] hdr,
    input  wire          mid_start,
    output wire          mid_done,
    input  wire          start,
    input  wire          cancel,
    output reg           busy,
    output reg           done,
    output reg  [7:0]    nsol,
    output reg  [15:0]   dropped,    // rows lost to full buckets (saturating)
    output reg           sol_avail,
    input  wire          sol_ack,
    // memory self-test (March C- on every table RAM)
    input  wire          bist_start,
    output wire          bist_done,
    output wire          bist_fail,
    input  wire [K-1:0]  sol_raddr,
    output wire [RW-1:0] sol_rdata
);
`ifndef SYNTHESIS
    initial begin
        if (GMAX < 2 || (GMAX & (GMAX-1)) != 0)
            $fatal(1, "GMAX must be a power of two >= 2");
        if (PACKED_TABLES != 0 && (COMPACT_VALUES == 0 || SPLIT_KEYS == 0))
            $fatal(1, "packed tables require compact values and separate keys");
        if (CHAIN != 0 && GROUP_REPLAY != 0)
            $fatal(1, "key chains do not support group replay");
        if (EMIT != 1 && !(EMIT == 2 && GBUF == 3 && STAGED_NETWORK == 2 && GROUP_REPLAY == 0))
            $fatal(1, "EMIT=2 needs GBUF=3, STAGED_NETWORK=2 and no group replay");
        if (GBUF != 2 && GBUF != 3)
            $fatal(1, "GBUF must be 2 or 3");
        if (HASH_UNITS < 1)
            $fatal(1, "HASH_UNITS must be at least 1");
        if (LEAF_SET != 0 && CB < K)
            $fatal(1, "leaf set needs K+1 probe bits within the leaf index");
        if (BUCKET0_SLOTS < SLOTS || BUCKET0_SLOTS > (1 << SB))
            $fatal(1, "bucket-zero capacity must cover SLOTS and fit slot bits");
    end
`endif
    // The first CB bits select the bucket/local key and are discarded by
    // pairing. Later rounds also fit in N-CB payload bits.
    localparam integer VW = (COMPACT_VALUES != 0) ? N-CB : N;
    localparam integer P    = 1 << PB;
    localparam integer HP   = 1 << HPB;           // hashing engines
    localparam integer HUW  = HASH_UNITS > 1 ? $clog2(HASH_UNITS) : 1;
    localparam integer HU_LAST = HASH_UNITS - 1;
    localparam integer LB   = CB - BB;            // local key bits
    localparam integer MW = (SPLIT_KEYS != 0) ? VW : LB+VW;
    localparam integer NLB  = 1 << LB;
    localparam integer NCA  = (1 << (BB - PB)) * NLB;     // hist entries per bank
    localparam integer JB   = BB - PB;            // local bucket bits
    localparam integer BPE  = 1 << JB;            // buckets per engine
    localparam integer S    = SLOTS;
    localparam integer EXTRA0 = BUCKET0_SLOTS - SLOTS;
    localparam integer INIT = 1 << (CB + 1);
    localparam integer IPHO = 512 / N;
    localparam integer HOUT = IPHO * N / 8;
    localparam integer NGRP = (INIT + IPHO - 1) / IPHO;
    localparam integer IW   = CB + 1;             // leaf index bits
    localparam integer PW   = BB + 2 * SB;        // pointer bits
    localparam integer FW   = (PW > IW) ? PW : IW;
    localparam integer XW   = ((BB + SB) > IW) ? (BB + SB) : IW;
    localparam integer LW   = $clog2(K + 1);
    localparam integer SEQW = $clog2(K * BPE + 2);
    localparam integer GW   = $clog2(GMAX + 1);
    localparam integer GI   = $clog2(GMAX);
    localparam integer GSW  = GBUF == 3 ? 2 : 1;   // buffer-select bits
    localparam integer SW   = $clog2(N + 1);
    localparam integer JW   = $clog2(IPHO + 1);
    localparam integer PA   = $clog2((K - 1) * (BPE * S + EXTRA0));  // largest bank
    localparam [K:0]    NSOL_C = NSOL[K:0];
    localparam [K:0]    TWO_K  = {{(K-1){1'b0}}, 2'b10};
    localparam [GW-1:0] GMAX_C = GMAX[GW-1:0];
    localparam [GW-1:0] TWO_G  = {{(GW-2){1'b0}}, 2'b10};
    localparam [LW-1:0] K_C    = K[LW-1:0];
    localparam [SB:0]   S_C    = S[SB:0];
    localparam [SB:0]   S0_C   = BUCKET0_SLOTS[SB:0];

    function [CB-1:0] key_of(input [N-1:0] v, input [SW-1:0] sh);
        reg [N-1:0] t;
        begin
            t = v >> sh;
            key_of = t[CB-1:0];
        end
    endfunction
    function [SW-1:0] shamt_of(input [LW-1:0] rr);   // N - rr*CB
        integer v;
        begin
            v = N - rr * CB;
            shamt_of = v[SW-1:0];
        end
    endfunction

    // Logical {bucket, slot} IDs stay stable in parent pointers. Pack only
    // the physical RAM address so non-power-of-two capacities save bits.
    function [JB+SB-1:0] row_addr(input [JB+SB-1:0] a, input [PB-1:0] bank);
        integer v;
        begin
            v = ({{(32-JB-SB){1'b0}}, a} >> SB) * S +
                ({{(32-JB-SB){1'b0}}, a} & ((1 << SB) - 1));
            // Bank zero's first bucket owns the extra rows. Shift its
            // later buckets so logical IDs cannot alias that extension.
            if (bank == 0 && a[JB+SB-1:SB] != 0) v = v + EXTRA0;
            row_addr = v[JB+SB-1:0];
        end
    endfunction

    // Each level occupies that bank's physical row count.
    function [PA-1:0] paddr_of(input [LW-1:0] lv, input [JB+SB-1:0] a,
                              input [PB-1:0] bank);
        integer v;
        begin
            v = ({{(32-LW){1'b0}}, lv} - 1) * (BPE*S + (bank == 0 ? EXTRA0 : 0)) +
                {{(32-JB-SB){1'b0}}, row_addr(a, bank)};
            paddr_of = v[PA-1:0];
        end
    endfunction
    // histogram sequence tag of bucket j in round rr: unique per attempt
    function [SEQW-1:0] seq_of(input [LW-1:0] rr, input [JB:0] jj);
        integer v;
        begin
            v = ({{(32-LW){1'b0}}, rr} - 1) * BPE + {{(31-JB){1'b0}}, jj} + 1;
            seq_of = v[SEQW-1:0];
        end
    endfunction

    // ============================================================ control
    reg [LW-1:0]  r;              // 0 = leaf generation, 1..K = rounds
    reg           go;             // pulse: engines start the current phase
    reg           fill_clr;       // pulse: clear the destination fill counters
    reg           clr_all;        // the current go is a full histogram clear
    wire [P-1:0]  at_bar;         // engine finished the current phase
    wire          all_bar = &at_bar;
    wire [SW-1:0] shamt   = shamt_of(r);                 // key of level r-1 rows
    wire [N-1:0]  lowmask = ~({N{1'b1}} << shamt);       // bits kept after pairing
    wire [SW-1:0] nshamt  = shamt - CB[SW-1:0];          // next key position
    wire          src_par = ~r[0];                       // level r-1 parity
    wire          dst_par = r[0];                        // level r parity (gen: 0)
    wire          last_rnd = (r == K_C);
    wire          x_busy;                                // expansion unit active

    // ============================================================ crossbar
    // engine request (flattened)
    wire [P-1:0]      q_v;
    wire [P*BB-1:0]   q_bkt;
    wire [P*VW-1:0]   q_val;
    wire [P*FW-1:0]   q_fld;
    wire [P*LB-1:0]   q_lk;      // low LB bits of the row's sort key
    // second emitter's request (EMIT = 2)
    wire [P-1:0]      q2_v, q2_g;
    wire [P*BB-1:0]   q2_bkt;
    wire [P*VW-1:0]   q2_val;
    wire [P*FW-1:0]   q2_fld;
    wire [P*LB-1:0]   q2_lk;
    wire [P-1:0]      q_g;       // grant to engine
    localparam integer ROW_WIDTH=VW+BB+LB+FW;
    wire [P*ROW_WIDTH-1:0] network_data;
    wire [P-1:0] network_valid,network_take;
    wire network_idle;
    // per-bank winner
    wire [P-1:0]      w_v;
    wire [P*PB-1:0]   w_src;

    genvar gb, ge;
    generate
        // requested bank of each engine = low PB bits of its bucket
        wire [P*PB-1:0] q_tgt;
        wire [P*ROW_WIDTH-1:0] q_data;
        for (gb = 0; gb < P; gb = gb + 1) begin : g_tgt
            assign q_tgt[gb*PB +: PB] = q_bkt[gb*BB +: PB];
            assign q_data[gb*ROW_WIDTH +: ROW_WIDTH] =
                {q_fld[gb*FW +: FW],q_lk[gb*LB +: LB],q_bkt[gb*BB +: BB],q_val[gb*VW +: VW]};
        end
        if(STAGED_NETWORK==2 && EMIT==2) begin : g_queue2   // queued crossbar, two producers per engine
            wire [P*PB-1:0] q2_tgt;
            wire [P*ROW_WIDTH-1:0] q2_data;
            wire [2*P-1:0] take2;
            for (gb = 0; gb < P; gb = gb + 1) begin : g_tgt2
                assign q2_tgt[gb*PB +: PB] = q2_bkt[gb*BB +: PB];
                assign q2_data[gb*ROW_WIDTH +: ROW_WIDTH] =
                    {q2_fld[gb*FW +: FW],q2_lk[gb*LB +: LB],q2_bkt[gb*BB +: BB],q2_val[gb*VW +: VW]};
            end
            zeq_row_queue #(.PB(PB),.DW(ROW_WIDTH),.DEPTH(QDEPTH),.SRCB(PB+1)) u_queue (
                .clk(clk),.rst(rst),.cancel(cancel),.in_valid({q2_v,q_v}),.in_target({q2_tgt,q_tgt}),
                .in_data({q2_data,q_data}),.in_take(take2),.out_valid(network_valid),
                .out_data(network_data),.idle(network_idle));
            assign network_take = take2[P-1:0];
            assign q2_g = take2[2*P-1:P];
        end else if(STAGED_NETWORK==2) begin : g_queue      // queued crossbar
            zeq_row_queue #(.PB(PB),.DW(ROW_WIDTH),.DEPTH(QDEPTH)) u_queue (
                .clk(clk),.rst(rst),.cancel(cancel),.in_valid(q_v),.in_target(q_tgt),.in_data(q_data),
                .in_take(network_take),.out_valid(network_valid),.out_data(network_data),.idle(network_idle));
            assign q2_g = {P{1'b0}};
        end else if(STAGED_NETWORK!=0) begin : g_network
            zeq_row_network #(.PB(PB),.DW(ROW_WIDTH)) u_network (
                .clk(clk),.rst(rst),.cancel(cancel),.in_valid(q_v),.in_target(q_tgt),.in_data(q_data),
                .in_take(network_take),.out_valid(network_valid),.out_data(network_data),.idle(network_idle));
            assign q2_g = {P{1'b0}};
        end else begin : g_no_network
            assign q2_g = {P{1'b0}};
            assign network_take=0;
            assign network_valid=0;
            assign network_data=0;
            assign network_idle=1'b1;
        end
        for (gb = 0; gb < P; gb = gb + 1) begin : g_arb
            wire          fv;
            wire [PB-1:0] fsel;
            zeq_xbar_arb #(.PB(PB), .BANK(gb)) u_arb (
                .clk(clk), .rst(rst), .req(STAGED_NETWORK==0?q_v:{P{1'b0}}), .tgt(q_tgt), .gv(fv), .gsel(fsel));
            assign w_v[gb] = STAGED_NETWORK!=0?network_valid[gb]:fv;
            assign w_src[gb*PB +: PB] = fsel;
        end
        for (ge = 0; ge < P; ge = ge + 1) begin : g_gnt
            wire [PB-1:0] bk = q_bkt[ge*BB +: PB];
            assign q_g[ge] = STAGED_NETWORK!=0?network_take[ge]:
                (q_v[ge] && w_v[bk] && (w_src[bk*PB +: PB] == ge[PB-1:0]));
        end
    endgenerate

    // ============================================= expansion-unit interface
    wire [P-1:0]      c_v;       // engine has a candidate
    wire [P*PW-1:0]   c_ptr;     // {bucket, slot a, slot b}
    reg  [P-1:0]      c_done;    // candidate finished (emitted or rejected)
    // bank read port for the expansion unit
    reg               x_rd_ptr, x_rd_idx;
    reg  [PB-1:0]     x_bank;
    reg  [PA-1:0]     x_paddr;
    reg  [LW-1:0]     x_plevel;
    reg  [JB+SB-1:0]  x_row_addr;
    reg  [JB+SB-1:0]  x_iaddr;
    wire [P*PW-1:0]   x_pq;
    wire [P*IW-1:0]   x_iq;
    reg  [PB-1:0]     x_bank_q;
    always @(posedge clk) x_bank_q <= x_bank;

    // ============================================================ engines
    wire [P-1:0]  e_mid_done;
    wire [P-1:0]  e_bd, e_bf;
    assign bist_done = &e_bd;
    assign bist_fail = |e_bf;
    wire [P*16-1:0] e_drop;
    assign mid_done = e_mid_done[0];

    generate
        for (ge = 0; ge < P; ge = ge + 1) begin : g_eng
            localparam integer ROWS = BPE*S + (ge == 0 ? EXTRA0 : 0);
            localparam integer ORDER_SLOTS = ge == 0 ? BUCKET0_SLOTS : S;
            // ---- engine state and signals the bank memories use
            //      (declared first: synthesis needs declaration before use)
            localparam [3:0] E_GREQ = 1, E_GWAIT = 2, E_GSEND = 3, E_BAR = 4,
                             E_BKT = 5, E_CA = 6, E_PS = 7, E_SC = 8, E_WK = 9;
            reg [3:0]       es;
            reg [JB:0]      j;
            reg [SB:0]      cnt, s;
            reg [SB-1:0]    s2, slb;
            reg             v2;
            reg [SB:0]      ia;
            wire [JB-1:0]   jj = j[JB-1:0];
            wire            hold_c;
            wire [SB-1:0]   oq;
            // ---- key chains (CHAIN): the per-key table holds {valid, newest
            //      slot} instead of a count and every row links to the row
            //      that held the key before it. The walker follows a chain at
            //      one row per cycle; a prefetcher looks up (and clears) the
            //      heads one key per cycle ahead of it.
            reg [LB:0]      pe;             // next key to look up
            reg             hq_pend;        // a head lookup sits on the RAM output
            reg             hd_v;           // buffered head
            reg [SB-1:0]    hd_slot;
            reg             hclr_v;         // clear the entry read last cycle
            reg [JB+LB-1:0] pra;
            reg             cfirst;         // row in stage C starts a chain
            wire [SB:0]     lq;             // link of the row in stage C
            wire            ch_cont, nxt_v, ch_pop, ch_rd;
            wire [SB-1:0]   nxt_slot;
            reg replay_start, replay_order_pending, replay_value_pending;
            reg [SB-1:0] replay_slot;
            wire replay_read, replay_valid, replay_ready, replay_done;
            wire [SB-1:0] replay_index, replay_a, replay_b;
            wire [VW-1:0] replay_xor;

            wire [SB:0]     fwd_off;
            wire            ca_we;
            wire [JB+LB-1:0] ca_a;
            // ================================================ bank memory
            // per parity: row values, row keys (low LB bits of the key the
            // rows will be sorted by), and a histogram of those keys per
            // bucket that is built as rows arrive
            // (all memories are zeq_ram: 1 write + 1 registered read port,
            //  each with its own March C- BIST)
            wire bd_m_val0, bd_m_val1, bd_m_hist0, bd_m_hist1;
            wire bd_link0, bd_link1, bf_link0, bf_link1;
            wire bd_m_ptr, bd_m_idx, bd_m_order, bd_key0, bd_key1;
            wire bf_m_val0, bf_m_val1, bf_m_hist0, bf_m_hist1;
            wire bf_m_ptr, bf_m_idx, bf_m_order, bf_key0, bf_key1;
            wire bd_packed, bf_packed;
            wire [VW-1:0] packed_value;
            wire [PW-1:0] packed_pointer;
            assign e_bd[ge] = (PACKED_TABLES != 0 ? bd_packed : (bd_m_val0 & bd_m_val1 & bd_m_ptr)) &
                              bd_m_hist0 & bd_m_hist1 & bd_m_idx & bd_m_order & bd_key0 & bd_key1 & bd_link0 & bd_link1;
            assign e_bf[ge] = (PACKED_TABLES != 0 ? bf_packed : (bf_m_val0 | bf_m_val1 | bf_m_ptr)) |
                              bf_m_hist0 | bf_m_hist1 | bf_m_idx | bf_m_order | bf_key0 | bf_key1 | bf_link0 | bf_link1;
            reg [SB:0]   fill  [0:2*BPE-1];     // {parity, bucket}
            reg [15:0]   drops;
            assign e_drop[ge*16 +: 16] = drops;

            // ---- crossbar write: stage 1 stores the row and reads the
            //      destination histogram, stage 2 writes the count back
            wire [PB-1:0]    wsrc  = w_src[ge*PB +: PB];
            wire [BB-1:0]    wbkt  = STAGED_NETWORK!=0?network_data[ge*ROW_WIDTH+VW +: BB]:q_bkt[wsrc*BB +: BB];
            wire [JB-1:0]    wj    = wbkt[BB-1:PB];
            wire [VW-1:0]    wval  = STAGED_NETWORK!=0?network_data[ge*ROW_WIDTH +: VW]:q_val[wsrc*VW +: VW];
            wire [FW-1:0]    wfld  = STAGED_NETWORK!=0?network_data[ge*ROW_WIDTH+VW+BB+LB +: FW]:q_fld[wsrc*FW +: FW];
            wire [LB-1:0]    wlk   = STAGED_NETWORK!=0?network_data[ge*ROW_WIDTH+VW+BB +: LB]:q_lk[wsrc*LB +: LB];
            wire [SB:0]      wslot = fill[{dst_par, wj}];
            wire [SB:0]      wlimit = wbkt == 0 ? S0_C : S_C;
            wire             wok   = w_v[ge] && (wslot < wlimit);
            wire [JB+SB-1:0] waddr = {wj, wslot[SB-1:0]};
            reg              w2v, w2pv;
            reg [JB+LB-1:0]  w2a, w2pa;
            wire [SB:0]      w2q;             // destination histogram read
            reg [SB:0]       w2pc;
            reg  [SB-1:0]    w2s;             // slot of the row in stage 2
            wire [SB:0]      w2old = (w2pv && w2pa == w2a) ? w2pc : w2q;
            wire [SB:0]      w2cnt = CHAIN != 0 ? {1'b1, w2s} : w2old + 1'b1;

            // ---- engine-side histogram port (source parity)
            reg              hs_rd, hs_we;
            reg [JB+LB-1:0]  hs_ra, hs_wa;
            reg [SB:0]       hs_wd;
            wire [SB:0]      hq;              // source histogram read

            integer ci;
            always @(posedge clk) begin
                if (rst || start) drops <= 0;       // per attempt
                w2v <= 1'b0;
                if (rst || fill_clr) begin
                    // Constant reset addresses avoid a large inferred write-priority network.
                    for (ci = 0; ci < 2*BPE; ci = ci + 1)
                        if (dst_par == ci[JB]) fill[ci] <= 0;
                    w2pv <= 1'b0;
                end else if (w_v[ge]) begin
                    if (wok) begin
                        fill[{dst_par, wj}] <= wslot + 1'b1;
                        w2v <= 1'b1;
                        w2a <= {wj, wlk};
                        w2s <= wslot[SB-1:0];
                    end else if (drops != 16'hFFFF) drops <= drops + 1'b1;
                end
                if (w2v) begin
                    w2pa <= w2a;
                    w2pc <= w2cnt;
                    w2pv <= 1'b1;
                end
            end

            // ---- values and keys: one {key, value} array per parity. Both
            //      are written together; the key alone is read in SC and
            //      key + value in WK (never both in one cycle), so one read
            //      port serves both. The key rides in the value word's
            //      spare macro bits (VW + LB <= the tiled width), which saves
            //      a separate flip-flop key array per parity.
            wire        wr_row  = w_v[ge] && wok;
            wire        vrd     = CHAIN != 0 ? (es == E_WK) && !hold_c && nxt_v :
                                  GROUP_REPLAY != 0 ? replay_order_pending : (es == E_WK) && !hold_c && vb;     // only a valid WK stage B needs a read
            wire        krd_sc  = (es == E_SC) && (s != cnt);
            wire [JB+SB-1:0] kra  = CHAIN != 0 ? {jj, nxt_slot} :
                                    krd_sc ? {jj, s[SB-1:0]} : {jj, GROUP_REPLAY != 0 ? oq : slb};
            wire        krd     = krd_sc || vrd;
            // Keep value RAM instance paths stable for existing floorplans.
            wire [LB+VW-1:0] row_write = {wlk, wval};
            wire [MW-1:0] vk0, vk1;
            wire value_rd = (SPLIT_KEYS != 0) ? vrd : krd;
            zeq_ram #(.AW(JB+SB), .DW(MW), .DEPTH(ROWS)) m_val0 (
                .clk(clk), .we(PACKED_TABLES == 0 && wr_row && !dst_par), .waddr(row_addr(waddr, ge[PB-1:0])), .wdata(row_write[MW-1:0]),
                .re(PACKED_TABLES == 0 && value_rd && !src_par), .raddr(row_addr(kra, ge[PB-1:0])), .rdata(vk0),
                .rst(rst), .bist_start(PACKED_TABLES == 0 ? bist_start : 1'b0), .bist_done(bd_m_val0), .bist_fail(bf_m_val0));
            zeq_ram #(.AW(JB+SB), .DW(MW), .DEPTH(ROWS)) m_val1 (
                .clk(clk), .we(PACKED_TABLES == 0 && wr_row && dst_par), .waddr(row_addr(waddr, ge[PB-1:0])), .wdata(row_write[MW-1:0]),
                .re(PACKED_TABLES == 0 && value_rd && src_par), .raddr(row_addr(kra, ge[PB-1:0])), .rdata(vk1),
                .rst(rst), .bist_start(PACKED_TABLES == 0 ? bist_start : 1'b0), .bist_done(bd_m_val1), .bist_fail(bf_m_val1));
            wire [MW-1:0] vkc = src_par ? vk1 : vk0;
            wire [VW-1:0] valc = PACKED_TABLES != 0 ? packed_value : vkc[VW-1:0];
            wire [LB-1:0] kcur;
            if (CHAIN != 0 && SPLIT_KEYS != 0) begin : g_chain_no_keys
                // the chain end marks the group boundary: no stored keys
                assign kcur = {LB{1'b0}};
                assign bd_key0 = 1'b1; assign bd_key1 = 1'b1;
                assign bf_key0 = 1'b0; assign bf_key1 = 1'b0;
                wire unused_krd = &{1'b0, krd};
            end else if (SPLIT_KEYS != 0) begin : g_split_keys
                wire [LB-1:0] key0, key1;
                zeq_ram #(.AW(JB+SB), .DW(LB), .DEPTH(ROWS)) m_key0 (
                    .clk(clk), .we(wr_row && !dst_par), .waddr(row_addr(waddr, ge[PB-1:0])), .wdata(wlk),
                    .re(krd && !src_par), .raddr(row_addr(kra, ge[PB-1:0])), .rdata(key0),
                    .rst(rst), .bist_start(bist_start), .bist_done(bd_key0), .bist_fail(bf_key0));
                zeq_ram #(.AW(JB+SB), .DW(LB), .DEPTH(ROWS)) m_key1 (
                    .clk(clk), .we(wr_row && dst_par), .waddr(row_addr(waddr, ge[PB-1:0])), .wdata(wlk),
                    .re(krd && src_par), .raddr(row_addr(kra, ge[PB-1:0])), .rdata(key1),
                    .rst(rst), .bist_start(bist_start), .bist_done(bd_key1), .bist_fail(bf_key1));
                assign kcur = src_par ? key1 : key0;
            end else begin : g_combined_keys
                assign kcur = vkc[MW-1 -: LB];
                assign bd_key0 = 1'b1; assign bd_key1 = 1'b1;
                assign bf_key0 = 1'b0; assign bf_key1 = 1'b0;
            end

            // ---- chain links: written in stage 2 beside the head update,
            //      read with the row's value
            if (CHAIN != 0) begin : g_link
                wire [SB:0] lq0, lq1;
                wire [JB+SB-1:0] w2ra = {w2a[JB+LB-1:LB], w2s};
                zeq_ram #(.AW(JB+SB), .DW(SB+1), .DEPTH(ROWS)) m_link0 (
                    .clk(clk), .we(w2v && !dst_par), .waddr(row_addr(w2ra, ge[PB-1:0])), .wdata(w2old),
                    .re(vrd && !src_par), .raddr(row_addr(kra, ge[PB-1:0])), .rdata(lq0),
                    .rst(rst), .bist_start(bist_start), .bist_done(bd_link0), .bist_fail(bf_link0));
                zeq_ram #(.AW(JB+SB), .DW(SB+1), .DEPTH(ROWS)) m_link1 (
                    .clk(clk), .we(w2v && dst_par), .waddr(row_addr(w2ra, ge[PB-1:0])), .wdata(w2old),
                    .re(vrd && src_par), .raddr(row_addr(kra, ge[PB-1:0])), .rdata(lq1),
                    .rst(rst), .bist_start(bist_start), .bist_done(bd_link1), .bist_fail(bf_link1));
                assign lq = src_par ? lq1 : lq0;
            end else begin : g_no_link
                assign lq = {(SB+1){1'b0}};
                assign bd_link0 = 1'b1; assign bd_link1 = 1'b1;
                assign bf_link0 = 1'b0; assign bf_link1 = 1'b0;
            end

            // ---- histograms: the destination parity is the bank's RMW,
            //      the source parity is the engine's; E_CA clears both
            wire [SB:0]   hq0, hq1;
            wire          h0_dst = !dst_par;
            zeq_ram #(.AW(JB+LB), .DW(SB+1)) m_hist0 (
                .clk(clk),
                .we(ca_we || (h0_dst ? w2v : hs_we)),
                .waddr(ca_we ? ca_a : (h0_dst ? w2a : hs_wa)),
                .wdata(ca_we ? {(SB+1){1'b0}} : (h0_dst ? w2cnt : hs_wd)),
                .re(h0_dst ? wr_row : hs_rd),
                .raddr(h0_dst ? {wj, wlk} : hs_ra), .rdata(hq0),
                .rst(rst), .bist_start(bist_start), .bist_done(bd_m_hist0), .bist_fail(bf_m_hist0));
            zeq_ram #(.AW(JB+LB), .DW(SB+1)) m_hist1 (
                .clk(clk),
                .we(ca_we || (!h0_dst ? w2v : hs_we)),
                .waddr(ca_we ? ca_a : (!h0_dst ? w2a : hs_wa)),
                .wdata(ca_we ? {(SB+1){1'b0}} : (!h0_dst ? w2cnt : hs_wd)),
                .re(!h0_dst ? wr_row : hs_rd),
                .raddr(!h0_dst ? {wj, wlk} : hs_ra), .rdata(hq1),
                .rst(rst), .bist_start(bist_start), .bist_done(bd_m_hist1), .bist_fail(bf_m_hist1));
            assign w2q = dst_par ? hq1 : hq0;
            assign hq  = src_par ? hq1 : hq0;

            // ---- pointers and leaf indices (read by the expansion unit)
            wire [PW-1:0] xpq;
            wire [IW-1:0] xiq;
            zeq_ram #(.AW(PA), .DW(PW), .DEPTH((K-1)*ROWS)) m_ptr (
                .clk(clk), .we(PACKED_TABLES == 0 && wr_row && r != 0), .waddr(paddr_of(r, waddr, ge[PB-1:0])),
                .wdata(wfld[PW-1:0]),
                .re(PACKED_TABLES == 0 && x_rd_ptr && x_bank == ge[PB-1:0]), .raddr(x_paddr), .rdata(xpq),
                .rst(rst), .bist_start(PACKED_TABLES == 0 ? bist_start : 1'b0), .bist_done(bd_m_ptr), .bist_fail(bf_m_ptr));
            zeq_ram #(.AW(JB+SB), .DW(IW), .DEPTH(ROWS)) m_idx (
                .clk(clk), .we(wr_row && r == 0), .waddr(row_addr(waddr, ge[PB-1:0])), .wdata(wfld[IW-1:0]),
                .re(x_rd_idx && x_bank == ge[PB-1:0]), .raddr(row_addr(x_iaddr, ge[PB-1:0])), .rdata(xiq),
                .rst(rst), .bist_start(bist_start), .bist_done(bd_m_idx), .bist_fail(bf_m_idx));
            assign x_pq[ge*PW +: PW] = PACKED_TABLES != 0 ? packed_pointer : xpq;
            assign x_iq[ge*IW +: IW] = xiq;

            if (PACKED_TABLES != 0) begin : g_packed
                zeq_packed_values #(.N(N), .K(K), .PW(PW), .AW(JB+SB), .DEPTH(ROWS)) u_tables (
                    .clk(clk), .rst(rst), .phase(r), .we(wr_row), .waddr(row_addr(waddr, ge[PB-1:0])),
                    .wvalue(wval), .wparent(wfld[PW-1:0]),
                    .re(value_rd), .raddr(row_addr(kra, ge[PB-1:0])), .rvalue(packed_value),
                    .pre(x_rd_ptr && x_bank == ge[PB-1:0]), .plevel(x_plevel), .paddr(x_row_addr),
                    .pvalue(packed_pointer), .bist_start(bist_start), .bist_done(bd_packed), .bist_fail(bf_packed));
            end else begin : g_no_packed
                assign packed_value = 0; assign packed_pointer = 0;
                assign bd_packed = 1'b1; assign bf_packed = 1'b0;
            end

            // ================================================ leaf hashing
            // HASH_UNITS Blake2b units per hashing engine. The engine's
            // groups go to its units in rotation and are consumed in the
            // same rotation, so the leaf order is that of a single unit;
            // only the wait between groups shrinks.
            reg  [HASH_UNITS-1:0]        hreq;
            reg  [32*HASH_UNITS-1:0]     hg;
            wire [HASH_UNITS-1:0]        hdone;
            wire [8*HOUT*HASH_UNITS-1:0] hdig_u;
            reg  [HUW-1:0]               cu;      // unit holding the next group
            wire [8*HOUT-1:0] hdig = hdig_u[cu*8*HOUT +: 8*HOUT];
            if (ge < HP) begin : g_h
                wire [HASH_UNITS-1:0] u_mid_done;
                genvar gu;
                for (gu = 0; gu < HASH_UNITS; gu = gu + 1) begin : g_unit
                    zeq_eh_hash #(.N(N), .K(K), .SPLIT(SPLIT)) u_hash (
                        .clk(clk), .rst(rst), .hdr(hdr), .mid_start(mid_start),
                        .mid_done(u_mid_done[gu]), .hash_start(hreq[gu]), .flush(cancel),
                        .g(hg[32*gu +: 32]), .hash_done(hdone[gu]),
                        .dig(hdig_u[8*HOUT*gu +: 8*HOUT]));
                end
                // all units compress the same block 0 in step
                assign e_mid_done[ge] = u_mid_done[0];
                wire unused_mid = &{1'b0, u_mid_done};
            end else begin : g_nh                 // no hash unit: no leaf groups
                assign e_mid_done[ge] = 1'b1;
                assign hdone  = {HASH_UNITS{1'b0}};
                assign hdig_u = {8*HOUT*HASH_UNITS{1'b0}};
                wire unused_h = &{1'b0, hreq, hg};
            end
            reg [8*HOUT-1:0] dig_r;
            wire [IPHO*N-1:0] slices;
            genvar gj, gt;
            for (gj = 0; gj < IPHO; gj = gj + 1) begin : g_slice
                for (gt = 0; gt < N / 8; gt = gt + 1) begin : g_byte
                    assign slices[gj*N + N-1-8*gt -: 8] = dig_r[8*(gj*(N/8)+gt) +: 8];
                end
            end

            // ================================================ local tables
            // order: SC writes, WK reads (never in the same phase)
            wire            ord_we = (es == E_SC) && v2;
            wire            ord_re = GROUP_REPLAY != 0 ? replay_read : (es == E_WK) && !hold_c && (ia != cnt);
            // (kept without a generate scope: testbenches and floorplans name it;
            //  with CHAIN it is idle)
            zeq_ram #(.AW(SB), .DW(SB), .DEPTH(ORDER_SLOTS)) m_order (
                .clk(clk), .we(ord_we), .waddr(fwd_off[SB-1:0]), .wdata(s2),
                .re(ord_re), .raddr(GROUP_REPLAY != 0 ? replay_index : ia[SB-1:0]), .rdata(oq),
                .rst(rst), .bist_start(bist_start), .bist_done(bd_m_order), .bist_fail(bf_m_order));

            // ================================================ engine FSM
            // per bucket: PS (prefix sum, 1 entry/cycle), SC (stable scatter,
            // 1 row/cycle), WK (walk 1 row/cycle; stalls while a finished
            // group's pairs go out, 1 pair/cycle). The bucket's histogram
            // entries are cleared in the background during WK.
            reg [31:0]      hgrp;           // hash group being sent
            reg             hnext;          // the next group's hash is running
            reg [HASH_UNITS-1:0] hd_l;      // done pulses already seen, per unit
            integer         hu;
            reg [JW-1:0]    jl;
            reg [LB:0]      e;
            reg [SB:0]      run;
            // two group buffers: one collects the next group while the
            // other emits its pairs
            reg [SB-1:0]    grow [0:(1<<GSW)*GMAX-1];
            reg [VW-1:0]    gval [0:(1<<GSW)*GMAX-1];
            reg [GSW-1:0]   csel, psel;     // collecting / pairing buffer
            // GBUF = 3: one finished group may wait in a third buffer
            reg             qv;
            reg [GSW-1:0]   qsel;
            reg [GW-1:0]    qcnt;
            reg [GW-1:0]    gcnt, pcnt, pa, pb;
            reg [LB-1:0]    gkey;
            // pipeline registers
            reg             v1, va, vb, vc, pvld, pairing, cwait;
            reg [SB-1:0]    s1, slc;
            reg [LB-1:0]    k2, pk, e1;
            reg [SB:0]      pv, ic;
            wire [LB-1:0]   k1  = kcur;      // SC: key of the row in stage 1
            wire [LB-1:0]   lkc = kcur;      // WK: key of the row in stage C
            reg [LB:0]      clr_e;          // background clear of bucket clr_j
            reg [JB-1:0]    clr_j;
            reg [JB+LB:0]   ca_i;           // full clear index
            localparam [JB+LB:0] NCA_C = NCA[JB+LB:0];
            assign          ca_we = (es == E_CA) && (ca_i != NCA_C);
            assign          ca_a  = ca_i[JB+LB-1:0];
            // request registers
            reg             rq_v;
            reg [BB-1:0]    rq_bkt;
            reg [LB-1:0]    rq_lk;
            reg [VW-1:0]    rq_val;
            reg [FW-1:0]    rq_fld;
            reg             cq_v;
            reg [PW-1:0]    cq_ptr;
            // second emitter: pairs the waiting group in its own buffer
            reg             rq2_v;
            reg [BB-1:0]    rq2_bkt;
            reg [LB-1:0]    rq2_lk;
            reg [VW-1:0]    rq2_val;
            reg [FW-1:0]    rq2_fld;
            reg [GW-1:0]    qa, qb;
            assign q2_v[ge]              = rq2_v;
            assign q2_bkt[ge*BB +: BB]   = rq2_bkt;
            assign q2_lk[ge*LB +: LB]    = rq2_lk;
            assign q2_val[ge*VW +: VW]   = rq2_val;
            assign q2_fld[ge*FW +: FW]   = rq2_fld;
            assign q_v[ge]               = rq_v;
            assign q_bkt[ge*BB +: BB]    = rq_bkt;
            assign q_lk[ge*LB +: LB]     = rq_lk;
            assign q_val[ge*VW +: VW]      = rq_val;
            assign q_fld[ge*FW +: FW]    = rq_fld;
            assign c_v[ge]               = cq_v;
            assign c_ptr[ge*PW +: PW]    = cq_ptr;
            assign at_bar[ge]            = (es == E_BAR) && !rq_v && !rq2_v && (clr_e == NLB[LB:0]);

            wire [N-1:0]     leaf    = slices[jl*N +: N];
            wire [31:0]      leafidx = hgrp * IPHO + {{(32-JW){1'b0}}, jl};
            wire [CB-1:0]    lkey    = key_of(leaf, shamt_of(1));
            wire [VW-1:0]    pair_payload = GROUP_REPLAY != 0 ? replay_xor : gval[{psel, pa[GI-1:0]}] ^ gval[{psel, pb[GI-1:0]}];
            wire [N-1:0]     pair_x = {{(N-VW){1'b0}}, pair_payload};
            wire [SB-1:0]    slot_a  = GROUP_REPLAY != 0 ? replay_a : grow[{psel, pa[GI-1:0]}];
            wire [SB-1:0]    slot_b  = GROUP_REPLAY != 0 ? replay_b : grow[{psel, pb[GI-1:0]}];
            wire [N-1:0]     nv      = pair_x & lowmask;
            wire [CB-1:0]    nkey    = key_of(nv, nshamt);
            wire [BB-1:0]    my_bkt  = {jj, ge[PB-1:0]};
            // Equal-valued parents XOR to an all-zero child. Before the last
            // round such a child descends from shared leaves (a genuine one
            // needs a 2^-(remaining bits) coincidence), and every one lands in
            // bucket zero, key zero. Both parents stay stored; only the child
            // is discarded, so it takes no slot and spawns no further pairs.
            wire             zero_child = (DROP_ZERO != 0) && !last_rnd && (nv == 0);
            // observability only: an emission slot consumed by a discard
            wire             zero_discard = zero_child && !cwait && (!rq_v || q_g[ge]) &&
                                 (GROUP_REPLAY != 0 ? replay_valid : pairing) && (es == E_WK);
            assign           fwd_off = (pvld && pk == k2) ? pv : hq;
            wire             c_boundary = (gcnt != 0) && (CHAIN != 0 ? cfirst : (lkc != gkey));
            assign           ch_cont  = vc && lq[SB];
            assign           nxt_v    = ch_cont || hd_v;
            assign           nxt_slot = ch_cont ? lq[SB-1:0] : hd_slot;
            assign           ch_pop   = !hold_c && !ch_cont && hd_v;
            // look up the next key when the RAM output will be free
            assign           ch_rd    = (CHAIN != 0) && (es == E_WK) && (pe != NLB[LB:0]) &&
                                        (!hq_pend || !hq[SB] || !hd_v || ch_pop);
            wire             pair_adv  = pairing && (cwait ? c_done[ge]
                                         : ((!rq_v || q_g[ge]) && !(last_rnd && nv == 0)));
            wire             pair_last = (pb == pcnt - 1'b1) && (pa == pcnt - TWO_G);
            wire             pair_free = !pairing || (pair_adv && pair_last);
            // a finished group of >= 2 needs the pairing buffer
            wire             handoff   = vc && c_boundary && gcnt >= TWO_G;
            // a finished group goes straight to pairing, or waits in the queue
            // EMIT = 2: outside the last round the waiting group is paired
            // where it sits, through the second request register
            wire             e2mode    = (EMIT == 2) && !last_rnd;
            wire [VW-1:0]    pair2_payload = gval[{qsel, qa[GI-1:0]}] ^ gval[{qsel, qb[GI-1:0]}];
            wire [N-1:0]     nv2       = {{(N-VW){1'b0}}, pair2_payload} & lowmask;
            wire [CB-1:0]    nkey2     = key_of(nv2, nshamt);
            wire             zero_child2 = (DROP_ZERO != 0) && (nv2 == 0);
            wire             q_adv     = e2mode && qv && (!rq2_v || q2_g[ge]);
            wire             q_last    = (qb == qcnt - 1'b1) && (qa == qcnt - TWO_G);
            wire             q_done    = q_adv && q_last;
            wire             zero_discard2 = q_adv && zero_child2 && (es == E_WK);
            wire             g_direct  = pair_free && (e2mode || !qv);
            wire             g_accept  = pair_free || (GBUF == 3 && !qv);
            wire [GSW+1:0]   csel_x    = {2'b00, csel};
            wire [GSW+1:0]   qsel_x    = {2'b00, qsel};
            wire [GSW+1:0]   psel_x    = {2'b00, psel};
            // the other buffer that stays occupied after this handoff
            wire             g_other_v = g_direct ? (qv && !q_done) : 1'b1;
            wire [1:0]       g_other   = (g_direct || (!e2mode && pair_free && qv)) ? qsel_x[1:0] : psel_x[1:0];
            wire [1:0]       g_free3   = g_other_v ? 2'd3 - g_other - csel_x[1:0]
                                                   : (csel_x[1:0] == 2'd2 ? 2'd0 : csel_x[1:0] + 2'd1);
            wire [GSW-1:0]   c_next    = GBUF == 3 ? g_free3[GSW-1:0] : ~csel;
            assign           hold_c    = handoff && !g_accept;
            wire             walk_done = (ic == cnt) && !va && !vb && !vc;

            assign replay_ready = cwait ? c_done[ge] :
                ((!rq_v || q_g[ge]) && !(last_rnd && nv == 0));
            if (GROUP_REPLAY != 0) begin : g_replay
                zeq_replay_pairs #(.AW(SB), .DW(VW), .KW(LB), .BUFFER(GMAX)) u_pairs (
                    .clk(clk), .rst(rst), .cancel(cancel), .start(replay_start), .count(cnt),
                    .rd(replay_read), .rindex(replay_index),
                    .row_valid(replay_value_pending), .row_slot(replay_slot),
                    .row_key(kcur), .row_value(valc), .valid(replay_valid),
                    .ready(replay_ready), .slot_a(replay_a), .slot_b(replay_b),
                    .pair_xor(replay_xor), .done(replay_done));
            end else begin : g_no_replay
                assign replay_read = 1'b0;
                assign replay_index = 0;
                assign replay_valid = 1'b0;
                assign replay_a = 0;
                assign replay_b = 0;
                assign replay_xor = 0;
                assign replay_done = 1'b0;
            end
            // One registered order read followed by one value/key read.
            always @(posedge clk) begin
                if (rst || cancel) begin
                    replay_order_pending <= 1'b0;
                    replay_value_pending <= 1'b0;
                end else begin
                    replay_order_pending <= replay_read;
                    replay_value_pending <= replay_order_pending;
                    if (replay_order_pending) replay_slot <= oq;
                end
            end

            // engine-side histogram controls
            always @* begin
                hs_rd = 1'b0; hs_ra = 0; hs_we = 1'b0; hs_wa = 0; hs_wd = 0;
                if (CHAIN != 0) begin
                    hs_rd = ch_rd; hs_ra = {jj, pe[LB-1:0]};
                    if (hclr_v) begin hs_we = 1'b1; hs_wa = pra; end
                end else if (es == E_PS) begin
                    hs_rd = (e != NLB[LB:0]); hs_ra = {jj, e[LB-1:0]};
                    if (v1) begin hs_we = 1'b1; hs_wa = {jj, e1}; hs_wd = run; end
                end else if (es == E_SC) begin
                    hs_rd = v1; hs_ra = {jj, k1};
                    if (v2) begin hs_we = 1'b1; hs_wa = {jj, k2}; hs_wd = fwd_off + 1'b1; end
                end else if (clr_e != NLB[LB:0]) begin
                    hs_we = 1'b1; hs_wa = {clr_j, clr_e[LB-1:0]}; hs_wd = 0;
                end
            end

            always @(posedge clk) begin
                if (rst || cancel) begin
                    es    <= E_BAR;
                    replay_start <= 1'b0;
                    rq_v  <= 1'b0;
                    cq_v  <= 1'b0;
                    hreq  <= {HASH_UNITS{1'b0}};
                    hnext <= 1'b0;
                    hd_l  <= {HASH_UNITS{1'b0}};
                    clr_e <= NLB[LB:0];
                    hclr_v <= 1'b0;
                    qv    <= 1'b0;
                    rq2_v <= 1'b0;
                    hq_pend <= 1'b0;
                    hd_v  <= 1'b0;
                    pe    <= NLB[LB:0];
                end else begin
                    hclr_v <= ch_rd;
                    if (ch_rd) pra <= {jj, pe[LB-1:0]};
                    replay_start <= 1'b0;
                    hreq <= {HASH_UNITS{1'b0}};
                    hd_l <= hd_l | hdone;
                    if (rq_v && q_g[ge]) rq_v <= 1'b0;
                    if (rq2_v && q2_g[ge]) rq2_v <= 1'b0;
                    if (hs_we && es != E_PS && es != E_SC && clr_e != NLB[LB:0])
                        clr_e <= clr_e + 1'b1;
                    case (es)
                    E_BAR: if (go) begin
                        if (clr_all) begin            // after reset / cancel
                            ca_i <= 0;
                            es   <= E_CA;
                        end else if (r == 0) begin    // new attempt: hash leaves
                            hgrp  <= ge;
                            cu    <= {HUW{1'b0}};
                            for (hu = 0; hu < HASH_UNITS; hu = hu + 1) begin
                                hreq[hu]        <= (ge < HP) && (ge + HP * hu < NGRP);
                                hg[32*hu +: 32] <= ge + HP * hu;
                            end
                            hnext <= 1'b0;
                            hd_l  <= {HASH_UNITS{1'b0}};
                            es    <= (ge < HP && ge < NGRP) ? E_GWAIT : E_BAR;
                        end else begin                // round r over my buckets
                            j  <= 0;
                            es <= E_BKT;
                        end
                    end
                    E_CA: if (ca_i == NCA_C) es <= E_BAR;
                          else ca_i <= ca_i + 1'b1;
                    // ---- leaf generation: send digest g while hashing g+HP
                    E_GWAIT: if (hdone[cu] || hd_l[cu]) begin
                        hd_l[cu] <= 1'b0;
                        dig_r <= hdig;
                        jl    <= 0;
                        // the freed unit takes the group HASH_UNITS ahead
                        if (hgrp + HP * HASH_UNITS < NGRP) begin
                            hreq[cu]        <= 1'b1;
                            hg[32*cu +: 32] <= hgrp + HP * HASH_UNITS;
                        end
                        hnext <= (hgrp + HP < NGRP);
                        cu    <= (cu == HU_LAST[HUW-1:0]) ? {HUW{1'b0}} : cu + 1'b1;
                        es <= E_GSEND;
                    end
                    E_GSEND: if (!rq_v || q_g[ge]) begin
                        if (jl == IPHO[JW-1:0] || leafidx >= INIT) begin
                            hgrp <= hgrp + HP;
                            es   <= hnext ? E_GWAIT : E_BAR;
                        end else begin
                            rq_v   <= 1'b1;
                            rq_bkt <= lkey[CB-1:LB];
                            rq_lk  <= lkey[LB-1:0];
                            rq_val <= leaf[VW-1:0];
                            rq_fld <= leafidx[FW-1:0];
                            jl     <= jl + 1'b1;
                        end
                    end
                    // ---- one bucket (wait for the previous bucket's clear)
                    E_BKT: if (clr_e == NLB[LB:0]) begin
                        if (j == BPE[JB:0]) es <= E_BAR;
                        else if (CHAIN != 0) begin    // chains are already grouped
                            cnt <= fill[{src_par, jj}];
                            ia <= 0; ic <= 0; va <= 1'b0; vb <= 1'b0; vc <= 1'b0;
                            gcnt <= 0; pairing <= 1'b0; cwait <= 1'b0; csel <= {GSW{1'b0}}; qv <= 1'b0;
                            pe <= 0; hq_pend <= 1'b0; hd_v <= 1'b0;
                            es <= E_WK;
                        end else begin
                            cnt <= fill[{src_par, jj}];
                            e   <= 0;
                            run <= 0;
                            v1  <= 1'b0;
                            es  <= E_PS;
                        end
                    end
                    E_PS: begin
                        if (v1) run <= run + hq;
                        if (e != NLB[LB:0]) begin e1 <= e[LB-1:0]; e <= e + 1'b1; v1 <= 1'b1; end
                        else begin
                            v1 <= 1'b0;
                            if (!v1) begin s <= 0; v2 <= 1'b0; pvld <= 1'b0; es <= E_SC; end
                        end
                    end
                    // ---- scatter: key read -> hist read -> order + hist write
                    E_SC: begin
                        if (v2) begin
                            pk   <= k2;
                            pv   <= fwd_off + 1'b1;
                            pvld <= 1'b1;
                        end
                        v2 <= v1;
                        k2 <= k1;
                        s2 <= s1;
                        if (s != cnt) begin
                            s1 <= s[SB-1:0];
                            s  <= s + 1'b1;
                            v1 <= 1'b1;
                        end else begin
                            v1 <= 1'b0;
                            if (!v1 && !v2) begin
                                ia <= 0; ic <= 0; va <= 1'b0; vb <= 1'b0; vc <= 1'b0;
                                gcnt <= 0; pairing <= 1'b0; cwait <= 1'b0; csel <= {GSW{1'b0}}; qv <= 1'b0;
                                clr_e <= 0; clr_j <= jj;     // clear this bucket in the background
                                replay_start <= (GROUP_REPLAY != 0);
                                es <= E_WK;
                            end
                        end
                    end
                    // ---- walk (A: order read, B: delay, C: VAL + key read)
                    //      and, concurrently, pairing of the previous group
                    E_WK: if (GROUP_REPLAY != 0) begin
                        if (replay_valid) begin
                            if (cwait && c_done[ge]) begin cq_v <= 1'b0; cwait <= 1'b0; end
                            if (!cwait && (!rq_v || q_g[ge])) begin
                                if (!last_rnd) begin
                                    if (!zero_child) begin
                                        rq_v <= 1'b1;
                                        rq_bkt <= nkey[CB-1:LB];
                                        rq_lk <= nkey[LB-1:0];
                                        rq_val <= nv[VW-1:0];
                                        rq_fld <= {{(FW-PW){1'b0}}, my_bkt, slot_a, slot_b};
                                    end
                                end else if (nv == 0) begin
                                    cq_v <= 1'b1;
                                    cq_ptr <= {my_bkt, slot_a, slot_b};
                                    cwait <= 1'b1;
                                end
                            end
                        end
                        if (replay_done) begin j <= j + 1'b1; es <= E_BKT; end
                    end else begin
                        // -------- pair emitter (pairing buffer psel)
                        if (pairing) begin
                            if (cwait && c_done[ge]) begin cq_v <= 1'b0; cwait <= 1'b0; end
                            if (!cwait && (!rq_v || q_g[ge])) begin
                                if (!last_rnd) begin
                                    if (!zero_child) begin
                                        rq_v   <= 1'b1;
                                        rq_bkt <= nkey[CB-1:LB];
                                        rq_lk  <= nkey[LB-1:0];
                                        rq_val <= nv[VW-1:0];
                                        rq_fld <= {{(FW-PW){1'b0}}, my_bkt, slot_a, slot_b};
                                    end
                                end else if (nv == 0) begin
                                    cq_v   <= 1'b1;
                                    cq_ptr <= {my_bkt, slot_a, slot_b};
                                    cwait  <= 1'b1;
                                end
                            end
                            if (pair_adv) begin
                                if (pair_last) pairing <= 1'b0;
                                else if (pb == pcnt - 1'b1) begin
                                    pa <= pa + 1'b1; pb <= pa + TWO_G;
                                end else pb <= pb + 1'b1;
                            end
                        end
                        // -------- a waiting group starts when the pairing buffer frees
                        // -------- second emitter (EMIT = 2): pair the waiting group in place
                        if (q_adv) begin
                            if (!zero_child2) begin
                                rq2_v   <= 1'b1;
                                rq2_bkt <= nkey2[CB-1:LB];
                                rq2_lk  <= nkey2[LB-1:0];
                                rq2_val <= nv2[VW-1:0];
                                rq2_fld <= {{(FW-PW){1'b0}}, my_bkt, grow[{qsel, qa[GI-1:0]}], grow[{qsel, qb[GI-1:0]}]};
                            end
                            if (q_last) qv <= 1'b0;
                            else if (qb == qcnt - 1'b1) begin
                                qa <= qa + 1'b1; qb <= qa + TWO_G;
                            end else qb <= qb + 1'b1;
                        end
                        if (GBUF == 3 && pair_free && qv && !e2mode) begin
                            pairing <= 1'b1; psel <= qsel; pcnt <= qcnt; pa <= 0; pb <= 1;
                            qv <= 1'b0;
                        end
                        // -------- walker / group collector (buffer csel)
                        if (vc && !hold_c) begin
                            if (handoff) begin
                                // finished group -> pairing buffer (or the queue); row opens a new group
                                if (g_direct) begin
                                    pairing <= 1'b1; psel <= csel; pcnt <= gcnt; pa <= 0; pb <= 1;
                                end else begin
                                    qv <= 1'b1; qsel <= csel; qcnt <= gcnt; qa <= 0; qb <= 1;
                                end
                                csel <= c_next;
                                grow[{c_next, {GI{1'b0}}}] <= slc;
                                gval[{c_next, {GI{1'b0}}}] <= valc;
                                gcnt <= 1;
                            end else if (c_boundary) begin      // group of 1: restart
                                grow[{csel, {GI{1'b0}}}] <= slc;
                                gval[{csel, {GI{1'b0}}}] <= valc;
                                gcnt <= 1;
                            end else if (gcnt < GMAX_C) begin
                                grow[{csel, gcnt[GI-1:0]}] <= slc;
                                gval[{csel, gcnt[GI-1:0]}] <= valc;
                                gcnt <= gcnt + 1'b1;
                            end
                            gkey <= lkc;
                            ic   <= ic + 1'b1;
                        end
                        if (CHAIN != 0) begin
                            // head buffer: refill from a finished lookup
                            if (ch_pop) hd_v <= 1'b0;
                            if (hq_pend) begin
                                if (!hq[SB]) hq_pend <= 1'b0;          // empty key
                                else if (!hd_v || ch_pop) begin
                                    hd_v    <= 1'b1;
                                    hd_slot <= hq[SB-1:0];
                                    hq_pend <= 1'b0;
                                end
                            end
                            if (ch_rd) begin hq_pend <= 1'b1; pe <= pe + 1'b1; end
                            if (!hold_c) begin
                                vc     <= nxt_v;   // value and link arrive next cycle
                                slc    <= nxt_slot;
                                cfirst <= !ch_cont;
                            end
                        end else if (!hold_c) begin
                            vc   <= vb;          // C: VAL/key data arrive this cycle
                            slc  <= slb;
                            vb   <= va;
                            slb  <= oq;          // B: slot from the order RAM
                            if (ia != cnt) begin
                                ia <= ia + 1'b1;
                                va <= 1'b1;
                            end else va <= 1'b0;
                        end
                        // -------- end of bucket: hand off the last group, drain
                        if (walk_done) begin
                            if (gcnt >= TWO_G) begin
                                if (g_accept) begin
                                    if (g_direct) begin
                                        pairing <= 1'b1; psel <= csel; pcnt <= gcnt; pa <= 0; pb <= 1;
                                    end else begin
                                        qv <= 1'b1; qsel <= csel; qcnt <= gcnt; qa <= 0; qb <= 1;
                                    end
                                    csel <= c_next;
                                    gcnt <= 0;
                                end
                            end else if (!pairing && !qv) begin
                                j <= j + 1'b1; es <= E_BKT;
                            end
                        end
                    end
                    default: es <= E_BAR;
                    endcase
                end
            end
        end
    endgenerate

    // ============================================================ control FSM
    // go/barrier protocol: set r, clear the destination fill counters, pulse
    // go, skip a cycle while the engines leave the barrier, then wait until
    // every engine is back at the barrier with no request in flight.
    // After reset or cancel the histograms may hold counts, so the next
    // attempt starts with a full clear (clr_all phase); a completed attempt
    // leaves them clean because every round clears what it consumed.
    localparam [3:0] K_IDLE = 0, K_CLR = 1, K_GO = 2, K_SKIP = 3, K_RUN = 4, K_FIN = 5,
                     K_CA = 6, K_CASKIP = 7, K_CAWAIT = 8;
    reg [3:0] kst;
    reg       dirty;
    always @(posedge clk) begin
        go       <= 1'b0;
        fill_clr <= 1'b0;
        done     <= 1'b0;
        if (rst || cancel) begin
            kst     <= K_IDLE;
            busy    <= 1'b0;
            r       <= 0;
            dirty   <= 1'b1;
            clr_all <= 1'b0;
        end else case (kst)
            K_IDLE: if (start) begin
                busy <= 1'b1;
                r    <= 0;
                kst  <= dirty ? K_CA : K_CLR;
            end
            K_CA:     begin clr_all <= 1'b1; go <= 1'b1; kst <= K_CASKIP; end
            K_CASKIP: kst <= K_CAWAIT;
            K_CAWAIT: if (all_bar) begin clr_all <= 1'b0; dirty <= 1'b0; kst <= K_CLR; end
            K_CLR:  begin fill_clr <= 1'b1; kst <= K_GO; end   // uses the new r
            K_GO:   begin go <= 1'b1; kst <= K_SKIP; end
            K_SKIP: kst <= K_RUN;
            // A producer grant may only enqueue a row in the staged fabric.
            // Drain every accepted row before changing destination parity.
            K_RUN:  if (all_bar && !x_busy && network_idle) begin
                if (last_rnd) kst <= K_FIN;
                else begin r <= r + 1'b1; kst <= K_CLR; end
            end
            K_FIN:  begin busy <= 1'b0; done <= 1'b1; kst <= K_IDLE; end
            default: kst <= K_IDLE;
        endcase
    end

    // drop counter (sum of banks, saturating)
    integer di_;
    reg [19:0] dsum;
    always @* begin
        dsum = 0;
        for (di_ = 0; di_ < P; di_ = di_ + 1) dsum = dsum + {4'd0, e_drop[di_*16 +: 16]};
    end
    always @(posedge clk) dropped <= (dsum > 20'hFFFF) ? 16'hFFFF : dsum[15:0];

    // ======================================================== expansion unit
    reg [XW-1:0] xbuf [0:NSOL-1];
    reg          xb_rd, xb_we;
    reg [K-1:0]  xb_a;
    reg [XW-1:0] xb_d, xbuf_q;
    always @(posedge clk) begin
        if (xb_we) xbuf[xb_a] <= xb_d;
        if (xb_rd) xbuf_q <= xbuf[xb_a];
    end
    assign sol_rdata = {{(RW-IW){1'b0}}, xbuf_q[IW-1:0]};

    localparam [4:0] X_IDLE = 0, X_A = 1, X_B = 2, X_E0 = 3, X_E1 = 4, X_E2 = 5,
                     X_E3 = 6, X_C0 = 7, X_C1 = 8, X_C2 = 9, X_O0 = 10, X_O1 = 11,
                     X_O2 = 12, X_S0 = 13, X_S1 = 14, X_S2 = 15, X_S3 = 16,
                     X_ON = 17, X_D0 = 18, X_D1 = 19, X_D2 = 20, X_EMIT = 21, X_FIN = 22,
                     X_H0 = 23, X_H1 = 24;
    reg [4:0]    xs;
    assign       x_busy = (xs != X_IDLE);
    reg [PB-1:0] xsel;
    reg [PW-1:0] xcand;
    reg [LW-1:0] lev;
    reg [K:0]    xe, len, s2, blk, t2, di, dj, dlim;
    reg          early;
    reg [XW-1:0] xfirst;
    reg [PW-1:0] xp;
    // entry = {bucket, slot}
    wire [BB-1:0] ent_b = xbuf_q[BB+SB-1:SB];
    wire [SB-1:0] ent_s = xbuf_q[SB-1:0];
    wire [PW-1:0] pq_sel = x_pq[x_bank_q*PW +: PW];
    wire [IW-1:0] iq_sel = x_iq[x_bank_q*IW +: IW];

    // Distinct-leaf set (LEAF_SET): each leaf index is inserted into an
    // open-addressed table of 2*NSOL slots as it is read, probing linearly
    // from its low K+1 bits. A candidate inserts at most NSOL leaves, so a
    // free slot always exists and every probe sequence ends. Meeting an equal
    // stored index rejects the candidate. This replaces the pairwise compare
    // of all NSOL leaves (NSOL^2/2 cycles) after canonical ordering; the
    // accepted and rejected candidates are the same.
    // X_C2 latches the leaf and its first probe slot, X_H0 inserts into a
    // free slot or reads the occupant, X_H1 compares and steps the probe.
    localparam integer HSB = K + 1;
    wire h_free;   // probe slot is empty: insert here
    wire h_hit;    // occupant equals the leaf: repeated index
    generate
        if (LEAF_SET != 0) begin : g_leaf_set
            reg [IW-1:0]          hset [0:(1<<HSB)-1];
            reg [(1<<HSB)-1:0]    hvalid;
            reg [HSB-1:0]         hp;
            reg [IW-1:0]          hkey, hset_q;
            assign h_free = !hvalid[hp];
            assign h_hit  = (hset_q == hkey);
            always @(posedge clk) begin
                if (xs == X_H0 && h_free) hset[hp] <= hkey;
                if (xs == X_H0 && !h_free) hset_q <= hset[hp];
            end
            always @(posedge clk) begin
                if (rst || xs == X_B) hvalid <= {(1<<HSB){1'b0}};
                else if (xs == X_H0 && h_free) hvalid[hp] <= 1'b1;
                if (xs == X_C2) begin
                    hkey <= iq_sel;
                    hp   <= iq_sel[HSB-1:0];
                end else if (xs == X_H1 && !h_hit) hp <= hp + 1'b1;
            end
        end else begin : g_no_leaf_set
            assign h_free = 1'b1;
            assign h_hit  = 1'b0;
        end
    endgenerate

    // pick a waiting engine (lowest index)
    reg          cand_any;
    reg [PB-1:0] cand_sel;
    integer ce;
    always @* begin
        cand_any = 1'b0;
        cand_sel = 0;
        for (ce = P - 1; ce >= 0; ce = ce - 1)
            if (c_v[ce] && !c_done[ce]) begin cand_any = 1'b1; cand_sel = ce[PB-1:0]; end
    end

    always @* begin
        xb_rd = 1'b0; xb_we = 1'b0; xb_a = 0; xb_d = 0;
        x_rd_ptr = 1'b0; x_rd_idx = 1'b0; x_bank = 0; x_paddr = 0; x_iaddr = 0; x_plevel = 0; x_row_addr = 0;
        case (xs)
            X_A:  begin xb_we = 1'b1; xb_a = 0; xb_d = {{(XW-BB-SB){1'b0}}, xcand[PW-1:2*SB], xcand[2*SB-1:SB]}; end
            X_B:  begin xb_we = 1'b1; xb_a = 1; xb_d = {{(XW-BB-SB){1'b0}}, xcand[PW-1:2*SB], xcand[SB-1:0]}; end
            X_E0: begin xb_rd = 1'b1; xb_a = xe[K-1:0]; end
            X_E1: begin
                x_rd_ptr = 1'b1;
                x_bank   = ent_b[PB-1:0];
                x_paddr  = paddr_of(lev, {ent_b[BB-1:PB], ent_s}, ent_b[PB-1:0]);
                x_plevel = lev;
                x_row_addr = row_addr({ent_b[BB-1:PB], ent_s}, ent_b[PB-1:0]);
            end
            X_E2: begin xb_we = 1'b1; xb_a = {xe[K-2:0], 1'b1}; xb_d = {{(XW-BB-SB){1'b0}}, pq_sel[PW-1:2*SB], pq_sel[SB-1:0]}; end
            X_E3: begin xb_we = 1'b1; xb_a = {xe[K-2:0], 1'b0}; xb_d = {{(XW-BB-SB){1'b0}}, xp[PW-1:2*SB], xp[2*SB-1:SB]}; end
            X_C0: begin xb_rd = 1'b1; xb_a = xe[K-1:0]; end
            X_C1: begin x_rd_idx = 1'b1; x_bank = ent_b[PB-1:0]; x_iaddr = {ent_b[BB-1:PB], ent_s}; end
            X_C2: begin xb_we = 1'b1; xb_a = xe[K-1:0]; xb_d = {{(XW-IW){1'b0}}, iq_sel}; end
            X_O0: begin xb_rd = 1'b1; xb_a = blk[K-1:0]; end
            X_O1: begin xb_rd = 1'b1; xb_a = blk[K-1:0] + s2[K-1:0]; end
            X_S0: begin xb_rd = 1'b1; xb_a = blk[K-1:0] + t2[K-1:0]; end
            X_S1: begin xb_rd = 1'b1; xb_a = blk[K-1:0] + s2[K-1:0] + t2[K-1:0]; end
            X_S2: begin xb_we = 1'b1; xb_a = blk[K-1:0] + t2[K-1:0]; xb_d = xbuf_q; end
            X_S3: begin xb_we = 1'b1; xb_a = blk[K-1:0] + s2[K-1:0] + t2[K-1:0]; xb_d = xfirst; end
            X_D0: begin xb_rd = 1'b1; xb_a = di[K-1:0]; end
            X_D1: begin xb_rd = 1'b1; xb_a = di[K-1:0] + 1'b1; end
            X_D2: begin xb_rd = 1'b1; xb_a = dj[K-1:0] + 1'b1; end
            X_EMIT: begin xb_rd = 1'b1; xb_a = sol_raddr; end
            default: ;
        endcase
    end

    always @(posedge clk) begin
        c_done <= {P{1'b0}};
        if (rst || cancel) begin
            xs        <= X_IDLE;
            sol_avail <= 1'b0;
            if (rst) nsol <= 0;
        end else begin
            if (start) nsol <= 0;
            case (xs)
            X_IDLE: if (cand_any) begin
                xsel  <= cand_sel;
                xcand <= c_ptr[cand_sel*PW +: PW];
                xs    <= X_A;
            end
            X_A: xs <= X_B;
            X_B: begin lev <= K_C - 1'b1; len <= 2; xe <= 1; early <= 1'b0; xs <= X_E0; end
            X_E0: xs <= X_E1;
            X_E1: xs <= X_E2;             // pointer read issued (entry from xbuf_q)
            X_E2: begin xp <= pq_sel; xs <= X_E3; end
            X_E3: begin
                xs <= X_E0;
                if (xe == 0) begin
                    len <= len << 1;
                    lev <= lev - 1'b1;
                    xe  <= (len << 1) - 1'b1;
                    if (lev == 1) begin xe <= 0; xs <= X_C0; end   // to leaves
                    else if ((len << 1) <= 8) begin
                        dlim <= len << 1; di <= 0; early <= 1'b1; xs <= X_D0;
                    end
                end else xe <= xe - 1'b1;
            end
            // ---- rows -> leaf indices
            X_C0: xs <= X_C1;
            X_C1: xs <= X_C2;
            X_C2: if (LEAF_SET != 0) xs <= X_H0;
            else begin
                if (xe == len - 1'b1) begin s2 <= 1; blk <= 0; xs <= X_O0; end
                else begin xe <= xe + 1'b1; xs <= X_C0; end
            end
            // ---- distinct-leaf set: insert, or compare with the occupant
            X_H0: if (h_free) begin
                if (xe == len - 1'b1) begin s2 <= 1; blk <= 0; xs <= X_O0; end
                else begin xe <= xe + 1'b1; xs <= X_C0; end
            end else xs <= X_H1;
            X_H1: xs <= h_hit ? X_FIN : X_H0;                 // repeated leaf: reject
            // ---- canonical order (as solver3)
            X_O0: xs <= X_O1;
            X_O1: begin xfirst <= xbuf_q; xs <= X_O2; end
            X_O2: if (xbuf_q < xfirst) begin t2 <= 0; xs <= X_S0; end
                  else xs <= X_ON;
            X_S0: xs <= X_S1;
            X_S1: begin xfirst <= xbuf_q; xs <= X_S2; end
            X_S2: xs <= X_S3;
            X_S3: if (t2 == s2 - 1'b1) xs <= X_ON;
                  else begin t2 <= t2 + 1'b1; xs <= X_S0; end
            X_ON: begin
                xs <= X_O0;
                if (blk + (s2 << 1) >= NSOL_C) begin
                    blk <= 0;
                    s2  <= s2 << 1;
                    if ((s2 << 1) == NSOL_C) begin
                        if (LEAF_SET != 0) begin sol_avail <= 1'b1; xs <= X_EMIT; end
                        else begin di <= 0; dlim <= NSOL_C; xs <= X_D0; end
                    end
                end else blk <= blk + (s2 << 1);
            end
            // ---- repeat check over dlim entries
            X_D0: xs <= X_D1;
            X_D1: begin xfirst <= xbuf_q; dj <= di + 1'b1; xs <= X_D2; end
            X_D2: begin
                if (xbuf_q == xfirst) xs <= X_FIN;        // repeat: reject
                else if (dj == dlim - 1'b1) begin
                    if (di == dlim - TWO_K) begin
                        if (early) begin early <= 1'b0; xs <= X_E0; end
                        else begin sol_avail <= 1'b1; xs <= X_EMIT; end
                    end else begin di <= di + 1'b1; xs <= X_D0; end
                end else dj <= dj + 1'b1;
            end
            X_EMIT: if (sol_ack) begin
                sol_avail <= 1'b0;
                if (nsol != 8'hFF) nsol <= nsol + 1'b1;
                xs <= X_FIN;
            end
            X_FIN: begin c_done[xsel] <= 1'b1; xs <= X_IDLE; end
            default: xs <= X_IDLE;
            endcase
        end
    end
endmodule

`default_nettype wire

// Exact pair enumeration over a bucket sorted by key. Keep at most BUFFER
// anchors; stream later partners, then reread the suffix with the next block.
// Every i<j with equal keys appears once, even equal values with distinct slots.
// One outstanding read, arbitrary positive response latency; cancel flushes it.
// This opt-in implementation trades buffer area for reads, not a speed claim.
`default_nettype none
module zeq_replay_pairs #(
    parameter integer AW = 7, DW = 180, KW = 8, BUFFER = 8
) (
    input wire clk, rst, cancel, start,
    input wire [AW:0] count,
    output wire rd,
    output wire [AW-1:0] rindex,
    input wire row_valid,
    input wire [AW-1:0] row_slot,
    input wire [KW-1:0] row_key,
    input wire [DW-1:0] row_value,
    output wire valid,
    input wire ready,
    output wire [AW-1:0] slot_a, slot_b,
    output wire [DW-1:0] pair_xor,
    output reg done
);
    localparam integer BI = $clog2(BUFFER);
    localparam [BI:0] BUFFER_C = BUFFER[BI:0];
    localparam [AW:0] STEP_C = BUFFER[AW:0];
    localparam [2:0] IDLE=0, READ=1, WAIT_ROW=2, PAIR=3, FINISH=4;
    reg [2:0] state;
    reg [AW:0] pos, limit, block_start, group_end;
    reg [BI:0] used;
    reg [BI-1:0] emit_index;
    reg [KW-1:0] key;
    reg [AW-1:0] slots [0:BUFFER-1];
    reg [DW-1:0] values [0:BUFFER-1];
    reg [AW-1:0] partner_slot;
    reg [DW-1:0] partner_value;
    assign rd = state == READ && pos < group_end && !rst && !cancel;
    assign rindex = pos[AW-1:0];
    assign valid = state == PAIR && !rst && !cancel;
    assign slot_a = slots[emit_index];
    assign slot_b = partner_slot;
    assign pair_xor = values[emit_index] ^ partner_value;
`ifndef SYNTHESIS
    initial if (BUFFER < 2 || BUFFER > (1 << AW))
        $fatal(1, "replay buffer must fit bucket address space and hold >= 2 rows");
`endif
    always @(posedge clk) begin
        if (rst || cancel) begin
            state <= IDLE; done <= 1'b0; used <= 0;
        end else begin
            done <= 1'b0;
            case (state)
            IDLE: if (start) begin
                pos <= 0; block_start <= 0; used <= 0;
                limit <= count; group_end <= count; state <= READ;
            end
            READ: if (pos < group_end) state <= WAIT_ROW;
                else if (used == BUFFER_C && group_end - block_start > STEP_C) begin
                    block_start <= block_start + STEP_C;
                    pos <= block_start + STEP_C; used <= 0;
                end else if (group_end < limit) begin
                    pos <= group_end; block_start <= group_end;
                    group_end <= limit; used <= 0;
                end else state <= FINISH;
            WAIT_ROW: if (row_valid) begin
                if (used != 0 && row_key != key) begin
                    group_end <= pos; state <= READ;
                end else if (used == 0) begin
                    key <= row_key; slots[0] <= row_slot; values[0] <= row_value;
                    used <= 1; pos <= pos + 1'b1; state <= READ;
                end else begin
                    partner_slot <= row_slot; partner_value <= row_value;
                    emit_index <= 0; state <= PAIR;
                end
            end
            PAIR: if (ready) begin
                if ({1'b0, emit_index} + 1'b1 == used) begin
                    if (used < BUFFER_C) begin
                        slots[used[BI-1:0]] <= partner_slot;
                        values[used[BI-1:0]] <= partner_value;
                        used <= used + 1'b1;
                    end
                    pos <= pos + 1'b1; state <= READ;
                end else emit_index <= emit_index + 1'b1;
            end
            FINISH: begin done <= 1'b1; state <= IDLE; end
            default: state <= IDLE;
            endcase
        end
    end
endmodule
`default_nettype wire
