// Equihash (N,K) solver, bucket-parallel edition (ZEQ-200X architecture).
//
// Rows of each level live in 2^BB buckets, chosen by the top BB bits of
// the row's *next* collision key; bucket d is stored in bank d % P, at
// most S = 2^SB slots per bucket. P engines each own one bank and process
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
    parameter integer GMAX = 16,
    parameter integer SPLIT = 1,   // Blake2b G steps per cycle
    parameter integer HPB  = PB,   // log2 leaf-hash units (<= PB); a test
                                   // chip needs one, a miner one per engine
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
    localparam integer P    = 1 << PB;
    localparam integer HP   = 1 << HPB;           // leaf-hash units
    localparam integer LB   = CB - BB;            // local key bits
    localparam integer NLB  = 1 << LB;
    localparam integer NCA  = (1 << (BB - PB)) * NLB;     // hist entries per bank
    localparam integer JB   = BB - PB;            // local bucket bits
    localparam integer BPE  = 1 << JB;            // buckets per engine
    localparam integer S    = 1 << SB;
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
    localparam integer SW   = $clog2(N + 1);
    localparam integer JW   = $clog2(IPHO + 1);
    localparam integer PA   = $clog2((K - 1) * BPE * S);  // PTR address bits
    localparam [K:0]    NSOL_C = NSOL[K:0];
    localparam [K:0]    TWO_K  = {{(K-1){1'b0}}, 2'b10};
    localparam [GW-1:0] GMAX_C = GMAX[GW-1:0];
    localparam [GW-1:0] TWO_G  = {{(GW-2){1'b0}}, 2'b10};
    localparam [LW-1:0] K_C    = K[LW-1:0];
    localparam [SB:0]   S_C    = S[SB:0];

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

    // PTR address of the rows of level lv (1..K-1): (lv-1)*BPE*S + local
    function [PA-1:0] paddr_of(input [LW-1:0] lv, input [JB+SB-1:0] a);
        integer v;
        begin
            v = ({{(32-LW){1'b0}}, lv} - 1) * BPE * S + {{(32-JB-SB){1'b0}}, a};
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
    wire [P*N-1:0]    q_val;
    wire [P*FW-1:0]   q_fld;
    wire [P*LB-1:0]   q_lk;      // low LB bits of the row's sort key
    wire [P-1:0]      q_g;       // grant to engine
    // per-bank winner
    wire [P-1:0]      w_v;
    wire [P*PB-1:0]   w_src;

    genvar gb, ge;
    generate
        // requested bank of each engine = low PB bits of its bucket
        wire [P*PB-1:0] q_tgt;
        for (gb = 0; gb < P; gb = gb + 1) begin : g_tgt
            assign q_tgt[gb*PB +: PB] = q_bkt[gb*BB +: PB];
        end
        for (gb = 0; gb < P; gb = gb + 1) begin : g_arb
            wire          fv;
            wire [PB-1:0] fsel;
            zeq_xbar_arb #(.PB(PB), .BANK(gb)) u_arb (
                .clk(clk), .rst(rst), .req(q_v), .tgt(q_tgt), .gv(fv), .gsel(fsel));
            assign w_v[gb] = fv;
            assign w_src[gb*PB +: PB] = fsel;
        end
        for (ge = 0; ge < P; ge = ge + 1) begin : g_gnt
            wire [PB-1:0] bk = q_bkt[ge*BB +: PB];
            assign q_g[ge] = q_v[ge] && w_v[bk] && (w_src[bk*PB +: PB] == ge[PB-1:0]);
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
            wire bd_m_ptr, bd_m_idx, bd_m_order;
            wire bf_m_val0, bf_m_val1, bf_m_hist0, bf_m_hist1;
            wire bf_m_ptr, bf_m_idx, bf_m_order;
            assign e_bd[ge] = bd_m_val0 & bd_m_val1 & bd_m_hist0 &
                              bd_m_hist1 & bd_m_ptr & bd_m_idx & bd_m_order;
            assign e_bf[ge] = bf_m_val0 | bf_m_val1 | bf_m_hist0 |
                              bf_m_hist1 | bf_m_ptr | bf_m_idx | bf_m_order;
            reg [SB:0]   fill  [0:2*BPE-1];     // {parity, bucket}
            reg [15:0]   drops;
            assign e_drop[ge*16 +: 16] = drops;

            // ---- crossbar write: stage 1 stores the row and reads the
            //      destination histogram, stage 2 writes the count back
            wire [PB-1:0]    wsrc  = w_src[ge*PB +: PB];
            wire [BB-1:0]    wbkt  = q_bkt[wsrc*BB +: BB];
            wire [JB-1:0]    wj    = wbkt[BB-1:PB];
            wire [N-1:0]     wval  = q_val[wsrc*N +: N];
            wire [FW-1:0]    wfld  = q_fld[wsrc*FW +: FW];
            wire [LB-1:0]    wlk   = q_lk[wsrc*LB +: LB];
            wire [SB:0]      wslot = fill[{dst_par, wj}];
            wire             wok   = w_v[ge] && (wslot < S_C);
            wire [JB+SB-1:0] waddr = {wj, wslot[SB-1:0]};
            reg              w2v, w2pv;
            reg [JB+LB-1:0]  w2a, w2pa;
            wire [SB:0]      w2q;             // destination histogram read
            reg [SB:0]       w2pc;
            wire [SB:0]      w2cnt = ((w2pv && w2pa == w2a) ? w2pc : w2q) + 1'b1;

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
                    for (ci = 0; ci < BPE; ci = ci + 1) fill[{dst_par, ci[JB-1:0]}] <= 0;
                    w2pv <= 1'b0;
                end else if (w_v[ge]) begin
                    if (wok) begin
                        fill[{dst_par, wj}] <= wslot + 1'b1;
                        w2v <= 1'b1;
                        w2a <= {wj, wlk};
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
            //      spare macro bits (N + LB <= the tiled width), which saves
            //      a separate flip-flop key array per parity.
            wire        wr_row  = w_v[ge] && wok;
            wire        vrd     = (es == E_WK) && !hold_c;     // WK stage B -> C
            wire        krd_sc  = (es == E_SC) && (s != cnt);
            wire [JB+SB-1:0] kra  = krd_sc ? {jj, s[SB-1:0]} : {jj, slb};
            wire        krd     = krd_sc || vrd;
            wire [LB+N-1:0] vk0, vk1;
            zeq_ram #(.AW(JB+SB), .DW(LB+N)) m_val0 (
                .clk(clk), .we(wr_row && !dst_par), .waddr(waddr), .wdata({wlk, wval}),
                .re(krd && !src_par), .raddr(kra), .rdata(vk0),
                .rst(rst), .bist_start(bist_start), .bist_done(bd_m_val0), .bist_fail(bf_m_val0));
            zeq_ram #(.AW(JB+SB), .DW(LB+N)) m_val1 (
                .clk(clk), .we(wr_row && dst_par), .waddr(waddr), .wdata({wlk, wval}),
                .re(krd && src_par), .raddr(kra), .rdata(vk1),
                .rst(rst), .bist_start(bist_start), .bist_done(bd_m_val1), .bist_fail(bf_m_val1));
            wire [LB+N-1:0] vkc = src_par ? vk1 : vk0;
            wire [N-1:0]  valc = vkc[N-1:0];
            wire [LB-1:0] kcur = vkc[LB+N-1:N];

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
            zeq_ram #(.AW(PA), .DW(PW), .DEPTH((K-1)*BPE*S)) m_ptr (
                .clk(clk), .we(wr_row && r != 0), .waddr(paddr_of(r, waddr)),
                .wdata(wfld[PW-1:0]),
                .re(x_rd_ptr && x_bank == ge[PB-1:0]), .raddr(x_paddr), .rdata(xpq),
                .rst(rst), .bist_start(bist_start), .bist_done(bd_m_ptr), .bist_fail(bf_m_ptr));
            zeq_ram #(.AW(JB+SB), .DW(IW)) m_idx (
                .clk(clk), .we(wr_row && r == 0), .waddr(waddr), .wdata(wfld[IW-1:0]),
                .re(x_rd_idx && x_bank == ge[PB-1:0]), .raddr(x_iaddr), .rdata(xiq),
                .rst(rst), .bist_start(bist_start), .bist_done(bd_m_idx), .bist_fail(bf_m_idx));
            assign x_pq[ge*PW +: PW] = xpq;
            assign x_iq[ge*IW +: IW] = xiq;

            // ================================================ leaf hashing
            reg              hreq;
            reg  [31:0]      hg;
            wire             hdone;
            wire [8*HOUT-1:0] hdig;
            if (ge < HP) begin : g_h
                zeq_eh_hash #(.N(N), .K(K), .SPLIT(SPLIT)) u_hash (
                    .clk(clk), .rst(rst), .hdr(hdr), .mid_start(mid_start),
                    .mid_done(e_mid_done[ge]), .hash_start(hreq), .flush(cancel),
                    .g(hg), .hash_done(hdone), .dig(hdig));
            end else begin : g_nh                 // no hash unit: no leaf groups
                assign e_mid_done[ge] = 1'b1;
                assign hdone = 1'b0;
                assign hdig  = {8*HOUT{1'b0}};
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
            wire            ord_re = (es == E_WK) && !hold_c && (ia != cnt);
            wire [SB-1:0]   oq;
            zeq_ram #(.AW(SB), .DW(SB)) m_order (
                .clk(clk), .we(ord_we), .waddr(fwd_off[SB-1:0]), .wdata(s2),
                .re(ord_re), .raddr(ia[SB-1:0]), .rdata(oq),
                .rst(rst), .bist_start(bist_start), .bist_done(bd_m_order), .bist_fail(bf_m_order));

            // ================================================ engine FSM
            // per bucket: PS (prefix sum, 1 entry/cycle), SC (stable scatter,
            // 1 row/cycle), WK (walk 1 row/cycle; stalls while a finished
            // group's pairs go out, 1 pair/cycle). The bucket's histogram
            // entries are cleared in the background during WK.
            reg [31:0]      hgrp;           // hash group being sent
            reg             hnext;          // the next group's hash is running
            reg             hd_l;           // its done pulse, if already seen
            reg [JW-1:0]    jl;
            reg [LB:0]      e;
            reg [SB:0]      run;
            // two group buffers: one collects the next group while the
            // other emits its pairs
            reg [SB-1:0]    grow [0:2*GMAX-1];
            reg [N-1:0]     gval [0:2*GMAX-1];
            reg             csel, psel;     // collecting / pairing buffer
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
            reg [N-1:0]     rq_val;
            reg [FW-1:0]    rq_fld;
            reg             cq_v;
            reg [PW-1:0]    cq_ptr;
            assign q_v[ge]               = rq_v;
            assign q_bkt[ge*BB +: BB]    = rq_bkt;
            assign q_lk[ge*LB +: LB]     = rq_lk;
            assign q_val[ge*N +: N]      = rq_val;
            assign q_fld[ge*FW +: FW]    = rq_fld;
            assign c_v[ge]               = cq_v;
            assign c_ptr[ge*PW +: PW]    = cq_ptr;
            assign at_bar[ge]            = (es == E_BAR) && !rq_v && (clr_e == NLB[LB:0]);

            wire [N-1:0]     leaf    = slices[jl*N +: N];
            wire [31:0]      leafidx = hgrp * IPHO + {{(32-JW){1'b0}}, jl};
            wire [CB-1:0]    lkey    = key_of(leaf, shamt_of(1));
            wire [N-1:0]     pair_x  = gval[{psel, pa[GI-1:0]}] ^ gval[{psel, pb[GI-1:0]}];
            wire [SB-1:0]    slot_a  = grow[{psel, pa[GI-1:0]}];
            wire [SB-1:0]    slot_b  = grow[{psel, pb[GI-1:0]}];
            wire [N-1:0]     nv      = pair_x & lowmask;
            wire [CB-1:0]    nkey    = key_of(nv, nshamt);
            wire [BB-1:0]    my_bkt  = {jj, ge[PB-1:0]};
            assign           fwd_off = (pvld && pk == k2) ? pv : hq;
            wire             c_boundary = (gcnt != 0) && (lkc != gkey);
            wire             pair_adv  = pairing && (cwait ? c_done[ge]
                                         : ((!rq_v || q_g[ge]) && !(last_rnd && nv == 0)));
            wire             pair_last = (pb == pcnt - 1'b1) && (pa == pcnt - TWO_G);
            wire             pair_free = !pairing || (pair_adv && pair_last);
            // a finished group of >= 2 needs the pairing buffer
            wire             handoff   = vc && c_boundary && gcnt >= TWO_G;
            assign           hold_c    = handoff && !pair_free;
            wire             walk_done = (ic == cnt) && !va && !vb && !vc;

            // engine-side histogram controls
            always @* begin
                hs_rd = 1'b0; hs_ra = 0; hs_we = 1'b0; hs_wa = 0; hs_wd = 0;
                if (es == E_PS) begin
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
                    rq_v  <= 1'b0;
                    cq_v  <= 1'b0;
                    hreq  <= 1'b0;
                    hnext <= 1'b0;
                    hd_l  <= 1'b0;
                    clr_e <= NLB[LB:0];
                end else begin
                    hreq <= 1'b0;
                    if (hdone) hd_l <= 1'b1;
                    if (rq_v && q_g[ge]) rq_v <= 1'b0;
                    if (hs_we && es != E_PS && es != E_SC && clr_e != NLB[LB:0])
                        clr_e <= clr_e + 1'b1;
                    case (es)
                    E_BAR: if (go) begin
                        if (clr_all) begin            // after reset / cancel
                            ca_i <= 0;
                            es   <= E_CA;
                        end else if (r == 0) begin    // new attempt: hash leaves
                            hgrp  <= ge;
                            hreq  <= (ge < HP);
                            hg    <= ge;
                            hnext <= 1'b0;
                            hd_l  <= 1'b0;
                            es    <= (ge < HP && ge < NGRP) ? E_GWAIT : E_BAR;
                        end else begin                // round r over my buckets
                            j  <= 0;
                            es <= E_BKT;
                        end
                    end
                    E_CA: if (ca_i == NCA_C) es <= E_BAR;
                          else ca_i <= ca_i + 1'b1;
                    // ---- leaf generation: send digest g while hashing g+HP
                    E_GWAIT: if (hdone || hd_l) begin
                        hd_l  <= 1'b0;
                        dig_r <= hdig;
                        jl    <= 0;
                        if (hgrp + HP < NGRP) begin hreq <= 1'b1; hg <= hgrp + HP; hnext <= 1'b1; end
                        else hnext <= 1'b0;
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
                            rq_val <= leaf;
                            rq_fld <= leafidx[FW-1:0];
                            jl     <= jl + 1'b1;
                        end
                    end
                    // ---- one bucket (wait for the previous bucket's clear)
                    E_BKT: if (clr_e == NLB[LB:0]) begin
                        if (j == BPE[JB:0]) es <= E_BAR;
                        else begin
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
                                gcnt <= 0; pairing <= 1'b0; cwait <= 1'b0; csel <= 1'b0;
                                clr_e <= 0; clr_j <= jj;     // clear this bucket in the background
                                es <= E_WK;
                            end
                        end
                    end
                    // ---- walk (A: order read, B: delay, C: VAL + key read)
                    //      and, concurrently, pairing of the previous group
                    E_WK: begin
                        // -------- pair emitter (pairing buffer psel)
                        if (pairing) begin
                            if (cwait && c_done[ge]) begin cq_v <= 1'b0; cwait <= 1'b0; end
                            if (!cwait && (!rq_v || q_g[ge])) begin
                                if (!last_rnd) begin
                                    rq_v   <= 1'b1;
                                    rq_bkt <= nkey[CB-1:LB];
                                    rq_lk  <= nkey[LB-1:0];
                                    rq_val <= nv;
                                    rq_fld <= {{(FW-PW){1'b0}}, my_bkt, slot_a, slot_b};
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
                        // -------- walker / group collector (buffer csel)
                        if (vc && !hold_c) begin
                            if (handoff) begin
                                // finished group -> pairing buffer; row opens a new group
                                pairing <= 1'b1; psel <= csel; pcnt <= gcnt; pa <= 0; pb <= 1;
                                csel <= ~csel;
                                grow[{~csel, {GI{1'b0}}}] <= slc;
                                gval[{~csel, {GI{1'b0}}}] <= valc;
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
                        if (!hold_c) begin
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
                                if (pair_free) begin
                                    pairing <= 1'b1; psel <= csel; pcnt <= gcnt; pa <= 0; pb <= 1;
                                    csel <= ~csel;
                                    gcnt <= 0;
                                end
                            end else if (!pairing) begin
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
            K_RUN:  if (all_bar && !x_busy) begin
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
                     X_ON = 17, X_D0 = 18, X_D1 = 19, X_D2 = 20, X_EMIT = 21, X_FIN = 22;
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
        x_rd_ptr = 1'b0; x_rd_idx = 1'b0; x_bank = 0; x_paddr = 0; x_iaddr = 0;
        case (xs)
            X_A:  begin xb_we = 1'b1; xb_a = 0; xb_d = {{(XW-BB-SB){1'b0}}, xcand[PW-1:2*SB], xcand[2*SB-1:SB]}; end
            X_B:  begin xb_we = 1'b1; xb_a = 1; xb_d = {{(XW-BB-SB){1'b0}}, xcand[PW-1:2*SB], xcand[SB-1:0]}; end
            X_E0: begin xb_rd = 1'b1; xb_a = xe[K-1:0]; end
            X_E1: begin
                x_rd_ptr = 1'b1;
                x_bank   = ent_b[PB-1:0];
                x_paddr  = paddr_of(lev, {ent_b[BB-1:PB], ent_s});
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
            X_C2: begin
                if (xe == len - 1'b1) begin s2 <= 1; blk <= 0; xs <= X_O0; end
                else begin xe <= xe + 1'b1; xs <= X_C0; end
            end
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
                    if ((s2 << 1) == NSOL_C) begin di <= 0; dlim <= NSOL_C; xs <= X_D0; end
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
