// ZEQ-200 digital core: link + LANES x (leaf hash + streaming solver +
// share filter). The collision histograms are inside each solver (on-chip
// SRAM); the share filter forwards only solutions meeting the pool target.
//
// EXT_MEM = 0: each lane's tables are on-chip SRAM (test-chip parameters).
// EXT_MEM = 1: each lane's three table ports leave the core (mainnet die),
//              flattened lane-major, for a DRAM controller to serve.
`default_nettype none

module zeq200_core #(
    parameter integer N       = 48,
    parameter integer K       = 5,
    parameter integer LANES   = 1,
    parameter integer EXT_MEM = 0,
    parameter integer SHARE_FILTER = 1, // 0: host filters solutions (test chip)
    parameter integer DIV     = 16,
    parameter integer HASH_SPLIT = 1,   // 4 on slow nodes (see zeq_blake2b)
    // ARCH 0: streaming solver (zeq_eh_solver3), tables on-chip or on ports
    // ARCH 1: bucket-parallel solver (zeq_eh_par), 2^PAR_PB engines with
    //         their own banks; always on-chip (EXT_MEM must be 0)
    parameter integer ARCH    = 0,
    parameter integer PAR_BB  = 4,
    parameter integer PAR_PB  = 2,
    parameter integer PAR_SB  = 8,
    parameter integer PAR_HPB = PAR_PB,   // log2 leaf-hash units (test chip: 0)
    // derived (do not override)
    parameter integer IPHO    = 512 / N,
    parameter integer HOUT    = IPHO * N / 8,
    parameter integer CB      = N / (K + 1),
    parameter integer RW      = CB + 2,
    parameter integer CW      = CB + 3,
    parameter integer CAP     = 1 << (CB + 2),
    parameter integer VVA     = CB + 3,
    parameter integer PVA     = $clog2((K - 1) * CAP)
) (
    input  wire       clk,
    input  wire       rst_n,      // RSTN pin, asynchronous
    output reg        rsto_n,     // re-driven to the next chip
    input  wire [1:0] addr_strap,
    input  wire       ci,
    output wire       co,
    input  wire       ri,
    output wire       ro,
    input  wire       bi,
    output wire       bo,
    input  wire [7:0] tsense,
    output wire       temp_pull,
    // external table ports (EXT_MEM = 1 only; tie off otherwise)
    output wire [LANES-1:0]        val_req_valid,
    input  wire [LANES-1:0]        val_req_ready,
    output wire [LANES-1:0]        val_req_we,
    output wire [LANES*VVA-1:0]    val_req_addr,
    output wire [LANES*N-1:0]      val_req_wdata,
    input  wire [LANES-1:0]        val_rsp_valid,
    input  wire [LANES*N-1:0]      val_rsp_rdata,
    output wire [LANES-1:0]        ptr_req_valid,
    input  wire [LANES-1:0]        ptr_req_ready,
    output wire [LANES-1:0]        ptr_req_we,
    output wire [LANES*PVA-1:0]    ptr_req_addr,
    output wire [LANES*2*RW-1:0]   ptr_req_wdata,
    input  wire [LANES-1:0]        ptr_rsp_valid,
    input  wire [LANES*2*RW-1:0]   ptr_rsp_rdata,
    output wire [LANES-1:0]        ord_req_valid,
    input  wire [LANES-1:0]        ord_req_ready,
    output wire [LANES-1:0]        ord_req_we,
    output wire [LANES*RW-1:0]     ord_req_addr,
    output wire [LANES*RW-1:0]     ord_req_wdata,
    input  wire [LANES-1:0]        ord_rsp_valid,
    input  wire [LANES*RW-1:0]     ord_rsp_rdata
);
    // reset: asynchronous assert, synchronous release
    reg [1:0] rst_s;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rst_s  <= 2'b00;
            rsto_n <= 1'b0;
        end else begin
            rst_s  <= {rst_s[0], 1'b1};
            rsto_n <= rst_s[1];
        end
    end
    wire rst = ~rst_s[1];

    wire [LANES*1120-1:0] hdr;
    wire                  mid_start;
    wire [LANES-1:0]      mid_done_l;
    wire [LANES-1:0]      lane_start, lane_done, lane_avail, lane_ack;
    wire                  lane_abort;
    wire [LANES*8-1:0]    lane_nsol;
    wire [K-1:0]          sol_raddr;
    wire [LANES*RW-1:0]   lane_rdata;
    wire [255:0]          target_be;
    wire                  bist_start;
    wire [LANES-1:0]      lane_bd, lane_bf;     // memory self-test per lane

    zeq_link #(.N(N), .K(K), .LANES(LANES), .DIV(DIV)) u_link (
        .clk(clk), .rst(rst), .addr_strap(addr_strap),
        .ci(ci), .co(co), .ri(ri), .ro(ro), .bi(bi), .bo(bo),
        .tsense(tsense), .temp_pull(temp_pull),
        .hdr_eff(hdr), .mid_start(mid_start), .mid_done(mid_done_l[0]),
        .lane_start(lane_start), .lane_abort(lane_abort), .lane_done(lane_done),
        .lane_nsol(lane_nsol), .lane_avail(lane_avail), .lane_ack(lane_ack),
        .sol_raddr(sol_raddr), .lane_rdata(lane_rdata), .target_be(target_be),
        .bist_start(bist_start), .bist_done(&lane_bd), .bist_fail(|lane_bf));

    genvar l;
    generate
        for (l = 0; l < LANES; l = l + 1) begin : g_lane
            wire              hreq, hdone, busy;
            // solver <-> share filter
            wire              s_avail, s_ack;
            wire [K-1:0]      s_raddr;
            wire [RW-1:0]     s_rdata;
            wire [15:0]       row_drops;    // rows lost to full buckets (ARCH 1)
            wire [15:0]       share_drops;  // solutions below the share target
            wire [31:0]       hg;
            wire [8*HOUT-1:0] hdig;
            // this lane's table ports
            wire vq_v, vq_r, vq_w, vr_v, pq_v, pq_r, pq_w, pr_v;
            wire oq_v, oq_r, oq_w, or_v;
            wire [VVA-1:0] vq_a;  wire [N-1:0]    vq_d, vr_d;
            wire [PVA-1:0] pq_a;  wire [2*RW-1:0] pq_d, pr_d;
            wire [RW-1:0]  oq_a, oq_d, or_d;

            if (SHARE_FILTER != 0) begin : g_share
                // only solutions that meet the share target reach the link
                zeq_share #(.N(N), .K(K)) u_share (
                    .clk(clk), .rst(rst), .cancel(lane_abort),
                    .hdr(hdr[l*1120 +: 1120]), .target_be(target_be),
                    .s_avail(s_avail), .s_ack(s_ack), .s_raddr(s_raddr), .s_rdata(s_rdata),
                    .l_avail(lane_avail[l]), .l_ack(lane_ack[l]),
                    .l_raddr(sol_raddr), .l_rdata(lane_rdata[l*RW +: RW]),
                    .dropped(share_drops));
            end else begin : g_no_share
                assign lane_avail[l] = s_avail;
                assign s_ack = lane_ack[l];
                assign s_raddr = sol_raddr;
                assign lane_rdata[l*RW +: RW] = s_rdata;
                assign share_drops = 16'd0;
            end

            if (ARCH == 1) begin : g_par
                zeq_eh_par #(.N(N), .K(K), .BB(PAR_BB), .PB(PAR_PB), .SB(PAR_SB),
                             .HPB(PAR_HPB), .SPLIT(HASH_SPLIT)) u_solver (
                    .clk(clk), .rst(rst), .hdr(hdr[l*1120 +: 1120]),
                    .mid_start(mid_start), .mid_done(mid_done_l[l]),
                    .start(lane_start[l]), .cancel(lane_abort), .busy(busy),
                    .done(lane_done[l]), .nsol(lane_nsol[l*8 +: 8]), .dropped(row_drops),
                    .sol_avail(s_avail), .sol_ack(s_ack),
                    .sol_raddr(s_raddr), .sol_rdata(s_rdata),
                    .bist_start(bist_start), .bist_done(lane_bd[l]), .bist_fail(lane_bf[l]));
                assign hreq = 1'b0; assign hg = 32'd0; assign hdone = 1'b0; assign hdig = 0;
                assign vq_v = 1'b0; assign vq_w = 1'b0; assign vq_a = 0; assign vq_d = 0;
                assign pq_v = 1'b0; assign pq_w = 1'b0; assign pq_a = 0; assign pq_d = 0;
                assign oq_v = 1'b0; assign oq_w = 1'b0; assign oq_a = 0; assign oq_d = 0;
                assign vr_v = 1'b0; assign vr_d = 0; assign vq_r = 1'b0;
                assign pr_v = 1'b0; assign pr_d = 0; assign pq_r = 1'b0;
                assign or_v = 1'b0; assign or_d = 0; assign oq_r = 1'b0;
                assign val_req_valid[l] = 1'b0;  assign val_req_we[l] = 1'b0;
                assign val_req_addr[l*VVA +: VVA] = 0;  assign val_req_wdata[l*N +: N] = 0;
                assign ptr_req_valid[l] = 1'b0;  assign ptr_req_we[l] = 1'b0;
                assign ptr_req_addr[l*PVA +: PVA] = 0;  assign ptr_req_wdata[l*2*RW +: 2*RW] = 0;
                assign ord_req_valid[l] = 1'b0;  assign ord_req_we[l] = 1'b0;
                assign ord_req_addr[l*RW +: RW] = 0;  assign ord_req_wdata[l*RW +: RW] = 0;
            end else begin : g_seq
                assign row_drops = 16'd0;
                assign lane_bd[l] = 1'b1;     // ARCH 0 memories have no BIST
                assign lane_bf[l] = 1'b0;
                zeq_eh_hash #(.N(N), .K(K), .SPLIT(HASH_SPLIT)) u_hash (
                    .clk(clk), .rst(rst), .hdr(hdr[l*1120 +: 1120]),
                    .mid_start(mid_start), .mid_done(mid_done_l[l]),
                    .hash_start(hreq), .flush(lane_abort), .g(hg), .hash_done(hdone), .dig(hdig));

                zeq_eh_solver3 #(.N(N), .K(K), .D((EXT_MEM != 0) ? 16 : 4)) u_solver (
                    .clk(clk), .rst(rst), .start(lane_start[l]), .cancel(lane_abort),
                    .busy(busy), .done(lane_done[l]), .nsol(lane_nsol[l*8 +: 8]),
                    .hreq(hreq), .hg(hg), .hdone(hdone), .hdig(hdig),
                    .sol_avail(s_avail), .sol_ack(s_ack),
                    .sol_raddr(s_raddr), .sol_rdata(s_rdata),
                    .val_req_valid(vq_v), .val_req_ready(vq_r), .val_req_we(vq_w),
                    .val_req_addr(vq_a), .val_req_wdata(vq_d),
                    .val_rsp_valid(vr_v), .val_rsp_rdata(vr_d),
                    .ptr_req_valid(pq_v), .ptr_req_ready(pq_r), .ptr_req_we(pq_w),
                    .ptr_req_addr(pq_a), .ptr_req_wdata(pq_d),
                    .ptr_rsp_valid(pr_v), .ptr_rsp_rdata(pr_d),
                    .ord_req_valid(oq_v), .ord_req_ready(oq_r), .ord_req_we(oq_w),
                    .ord_req_addr(oq_a), .ord_req_wdata(oq_d),
                    .ord_rsp_valid(or_v), .ord_rsp_rdata(or_d));

                if (EXT_MEM != 0) begin : g_ext
                    assign val_req_valid[l] = vq_v;  assign vq_r = val_req_ready[l];
                    assign val_req_we[l]    = vq_w;
                    assign val_req_addr[l*VVA +: VVA] = vq_a;
                    assign val_req_wdata[l*N +: N]    = vq_d;
                    assign vr_v = val_rsp_valid[l];  assign vr_d = val_rsp_rdata[l*N +: N];
                    assign ptr_req_valid[l] = pq_v;  assign pq_r = ptr_req_ready[l];
                    assign ptr_req_we[l]    = pq_w;
                    assign ptr_req_addr[l*PVA +: PVA]     = pq_a;
                    assign ptr_req_wdata[l*2*RW +: 2*RW]  = pq_d;
                    assign pr_v = ptr_rsp_valid[l];  assign pr_d = ptr_rsp_rdata[l*2*RW +: 2*RW];
                    assign ord_req_valid[l] = oq_v;  assign oq_r = ord_req_ready[l];
                    assign ord_req_we[l]    = oq_w;
                    assign ord_req_addr[l*RW +: RW]  = oq_a;
                    assign ord_req_wdata[l*RW +: RW] = oq_d;
                    assign or_v = ord_rsp_valid[l];  assign or_d = ord_rsp_rdata[l*RW +: RW];
                end else begin : g_int
                    zeq_sram_port #(.AW(VVA), .DW(N), .DEPTH(2 * CAP)) m_val (
                        .clk(clk), .req_valid(vq_v), .req_ready(vq_r), .req_we(vq_w),
                        .req_addr(vq_a), .req_wdata(vq_d), .rsp_valid(vr_v), .rsp_rdata(vr_d));
                    zeq_sram_port #(.AW(PVA), .DW(2 * RW), .DEPTH((K - 1) * CAP)) m_ptr (
                        .clk(clk), .req_valid(pq_v), .req_ready(pq_r), .req_we(pq_w),
                        .req_addr(pq_a), .req_wdata(pq_d), .rsp_valid(pr_v), .rsp_rdata(pr_d));
                    zeq_sram_port #(.AW(RW), .DW(RW), .DEPTH(CAP)) m_ord (
                        .clk(clk), .req_valid(oq_v), .req_ready(oq_r), .req_we(oq_w),
                        .req_addr(oq_a), .req_wdata(oq_d), .rsp_valid(or_v), .rsp_rdata(or_d));
                    assign val_req_valid[l] = 1'b0;  assign val_req_we[l] = 1'b0;
                    assign val_req_addr[l*VVA +: VVA] = 0;  assign val_req_wdata[l*N +: N] = 0;
                    assign ptr_req_valid[l] = 1'b0;  assign ptr_req_we[l] = 1'b0;
                    assign ptr_req_addr[l*PVA +: PVA] = 0;  assign ptr_req_wdata[l*2*RW +: 2*RW] = 0;
                    assign ord_req_valid[l] = 1'b0;  assign ord_req_we[l] = 1'b0;
                    assign ord_req_addr[l*RW +: RW] = 0;  assign ord_req_wdata[l*RW +: RW] = 0;
                end
            end
        end
    endgenerate
endmodule

`default_nettype wire
