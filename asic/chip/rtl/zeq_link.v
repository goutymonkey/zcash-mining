// ZEQ-200 chain link: protocol, job control, lane dispatch, up/down UARTs.
//
// Downstream (controller -> chips), on CI and re-driven on CO:
//   A5 | type | addr | len_lo | len_hi | payload | crc8(type..payload)
//   0x01 JOB     payload = job id (1) + 140-byte Equihash input
//   0x02 STOP
//   0x03 SET_OT  payload = over-temperature threshold (sensor code)
//   0x04 PING
//   0x05 SET_TARGET payload = 32-byte share target, big-endian
//   0x06 BIST     run the memory self-test (empty payload; ignored while mining)
// JOBs received during BIST wait for PASS; the latest JOB replaces the queued
// one, and STOP cancels it without interrupting the destructive test. FAIL
// discards queued work and blocks mining until a successful BIST or reset.
//   addr 0xFF is broadcast; otherwise it must match the ADDR straps.
// Every chip re-drives CI onto CO, so all chips see every packet.
// Command lengths must match their type. An incomplete command is discarded
// after 32 UART byte budgets without a received byte. The controller must
// leave that idle gap after an interrupted frame before sending a new one.
// SOF-like bytes inside a complete payload remain data, not restart markers.
//
// Upstream (chips -> controller), received on RI and sent on RO:
//   5A | type | addr | len_lo | len_hi | payload | crc8
//   0x81 SOLUTION payload = job id, attempt (LE24), 2^K indices (BE32)
//   0x84 PONG     payload = version, status, sensor code, lanes
//                 status = {4'b0, bist_fail, bist_done, busy, over_temp}
// busy includes BIST and a latched test failure; stale results are hidden
// while a new test is starting/running. HAS_BIST=0 reports no BIST result.
//   0x85 DONE     payload = job id, attempt (LE24), solution count
// Packets arriving on RI are forwarded whole; this chip's own packets are
// sent only between them, so upstream framing is never interleaved. When
// both are waiting the link alternates packet by packet. The four-chip
// board straps addresses in order: 0 nearest the controller, then 1,2,3.
// Each hop paces aggregate transmission to reserve one quarter of the
// line's capacity for each upstream (lower-addressed) chip's own reports.
// Flow control: the RI buffer holds two maximum-size packets, and this
// chip starts one of its own only while the buffer is at most half full
// (minus a margin for oscillator offset), so bytes arriving meanwhile always
// fit. Headroom alone cannot prevent starvation or long-term overflow with
// unequal clocks: a continuously busy downstream sender must be slower than
// its receiving hop. The pacing below provides that bandwidth difference.
// Correct strap order and qualified UART clock tolerances are required.
// A broken upstream frame must not monopolize the transmitter indefinitely:
// oversized payloads are abandoned, and an empty forwarding FIFO times out
// after 32 byte budgets. Valid tail pacing is about four byte budgets. Bytes
// already forwarded cannot be recalled; the controller must resynchronize
// damaged frames using bounded lengths, CRC and an inter-byte timeout.
//
// Nonce ownership: input bytes 136..139 become {chip address, 24-bit
// attempt LE}. Attempts are handed to whichever solver lane is idle, so
// every chip (and every lane) works a disjoint nonce space from one
// broadcast JOB. Every report carries the job id of the attempt it
// belongs to (captured when the attempt starts), never the current job, so
// a report still queued when a new JOB arrives cannot be mislabeled. A new
// JOB drops unsent DONE reports of the old job; a solution already being
// sent finishes first.
`default_nettype none

module zeq_link #(
    parameter integer N       = 48,
    parameter integer K       = 5,
    parameter integer LANES   = 1,
    parameter integer DIV     = 16,   // UART clocks per bit
    parameter integer HAS_BIST = 1,   // ARCH 0 has no test engine/handshake
    parameter integer BOOT_BIST = 0,  // production: test after every reset before mining
    parameter [7:0]   VERSION = 8'h02,
    // derived (do not override)
    parameter integer CB      = N / (K + 1),
    parameter integer RW      = CB + 2,
    parameter integer NSOL    = 1 << K,
    // RI buffer holds two of the largest packets (a forwarded one can
    // arrive while this chip sends its own)
    parameter integer FIFO_AW = $clog2(2 * (4 * NSOL + 16)),
    parameter integer LW      = (LANES > 1) ? $clog2(LANES) : 1
) (
    input  wire                  clk,
    input  wire                  rst,
    input  wire [1:0]            addr_strap,
    input  wire                  ci,
    output reg                   co,
    input  wire                  ri,
    output wire                  ro,
    input  wire                  bi,         // high = everything downstream idle
    output reg                   bo,
    input  wire [7:0]            tsense,
    output reg                   temp_pull,  // drive the open-drain TEMP pin low
    // hash units (shared midstate, per-lane header)
    output wire [LANES*1120-1:0] hdr_eff,
    output reg                   mid_start,
    input  wire                  mid_done,
    // solver lanes
    output reg  [LANES-1:0]      lane_start,
    output reg                   lane_abort,
    input  wire [LANES-1:0]      lane_done,
    input  wire [LANES*8-1:0]    lane_nsol,
    input  wire [LANES-1:0]      lane_avail,
    output reg  [LANES-1:0]      lane_ack,
    output reg  [K-1:0]          sol_raddr,
    input  wire [LANES*RW-1:0]   lane_rdata,
    output reg  [255:0]          target_be,  // share target (SET_TARGET)
    output reg                   bist_start,
    input  wire                  bist_done,
    input  wire                  bist_fail
);
    localparam [7:0] DOWN_SOF = 8'hA5, UP_SOF = 8'h5A;
    localparam [7:0] CMD_JOB = 8'h01, CMD_STOP = 8'h02, CMD_SET_OT = 8'h03, CMD_PING = 8'h04;
    localparam [7:0] CMD_SET_TARGET = 8'h05, CMD_BIST = 8'h06;
    localparam [7:0] RSP_SOL = 8'h81, RSP_PONG = 8'h84, RSP_DONE = 8'h85;
    localparam [15:0] JOB_LEN = 16'd141;
    localparam [15:0] SOL_LEN = 16'd4 + NSOL[13:0] * 16'd4;
    localparam [7:0]  LANES_B = LANES[7:0];

    wire [7:0] my_id = {6'd0, addr_strap};

    function [7:0] crc8(input [7:0] c, input [7:0] b);   // poly 0x07
        reg [7:0] x;
        integer k;
        begin
            x = c ^ b;
            for (k = 0; k < 8; k = k + 1)
                x = x[7] ? ((x << 1) ^ 8'h07) : (x << 1);
            crc8 = x;
        end
    endfunction

    // ------------------------------------------ CI -> CO re-drive
    reg [1:0] ci_s, bi_s;
    always @(posedge clk) begin
        if (rst) begin
            ci_s <= 2'b11;
            co   <= 1'b1;
            bi_s <= 2'b11;
        end else begin
            ci_s <= {ci_s[0], ci};
            co   <= ci_s[1];
            bi_s <= {bi_s[0], bi};
        end
    end

    // ---------------------------------------------- downstream parser
    wire       d_valid;
    wire [7:0] d_byte;
    zeq_uart_rx #(.DIV(DIV)) u_rx_down (
        .clk(clk), .rst(rst), .rxd(ci), .valid(d_valid), .data(d_byte));

    localparam [2:0] P_SOF = 0, P_TYP = 1, P_ADR = 2, P_L0 = 3, P_L1 = 4, P_PAY = 5, P_CRC = 6;
    reg [2:0]    pst;
    reg [7:0]    ptyp, padr, pcrc, ot_stage, ot_thresh, job_stage;
    reg [15:0]   plen, pcnt;
    reg [1119:0] stage;
    reg [255:0]  tgt_stage;
    reg          cmd_job, cmd_stop, cmd_ping, cmd_bist;
    wire [7:0]   pbyte_idx = pcnt[7:0] - 8'd1;   // JOB header byte index
    localparam integer CMD_GAP_LIMIT = 32 * (10 * DIV + 8);
    localparam integer CMD_GAP_W = $clog2(CMD_GAP_LIMIT + 1);
    reg [CMD_GAP_W-1:0] command_gap;
    wire command_timeout = pst != P_SOF && !d_valid &&
                           command_gap == CMD_GAP_W'(CMD_GAP_LIMIT - 1);
    always @(posedge clk) begin
        if (rst || pst == P_SOF || d_valid) command_gap <= 0;
        else if (!command_timeout) command_gap <= command_gap + 1'b1;
    end
    function command_length_valid(input [7:0] typ, input [15:0] length);
        begin
            case (typ)
                CMD_JOB: command_length_valid = length == JOB_LEN;
                CMD_STOP, CMD_PING, CMD_BIST: command_length_valid = length == 0;
                CMD_SET_OT: command_length_valid = length == 1;
                CMD_SET_TARGET: command_length_valid = length == 32;
                default: command_length_valid = 1'b0;
            endcase
        end
    endfunction

    always @(posedge clk) begin
        cmd_job  <= 1'b0;
        cmd_stop <= 1'b0;
        cmd_ping <= 1'b0;
        cmd_bist <= 1'b0;
        if (rst) begin
            pst       <= P_SOF;
            ot_thresh <= 8'd200;
            target_be <= {256{1'b1}};    // accept every solution
        end else if (command_timeout) begin
            pst <= P_SOF;
        end else if (d_valid) begin
            case (pst)
            P_SOF: if (d_byte == DOWN_SOF) begin pcrc <= 8'd0; pst <= P_TYP; end
            P_TYP: begin ptyp <= d_byte; pcrc <= crc8(pcrc, d_byte); pst <= P_ADR; end
            P_ADR: begin padr <= d_byte; pcrc <= crc8(pcrc, d_byte); pst <= P_L0; end
            P_L0:  begin plen[7:0] <= d_byte; pcrc <= crc8(pcrc, d_byte); pst <= P_L1; end
            P_L1: begin
                plen[15:8] <= d_byte;
                pcrc <= crc8(pcrc, d_byte);
                pcnt <= 16'd0;
                if (!command_length_valid(ptyp, {d_byte, plen[7:0]}))
                    pst <= P_SOF;
                else pst <= ({d_byte, plen[7:0]} == 16'd0) ? P_CRC : P_PAY;
            end
            P_PAY: begin
                if (ptyp == CMD_JOB) begin
                    if (pcnt == 16'd0) job_stage <= d_byte;
                    else if (pcnt <= 16'd140) stage[8 * pbyte_idx +: 8] <= d_byte;
                end
                if (ptyp == CMD_SET_OT && pcnt == 16'd0) ot_stage <= d_byte;
                if (ptyp == CMD_SET_TARGET && pcnt < 16'd32)
                    tgt_stage <= {tgt_stage[247:0], d_byte};   // big-endian
                pcrc <= crc8(pcrc, d_byte);
                pcnt <= pcnt + 1'b1;
                if (pcnt == plen - 1'b1) pst <= P_CRC;
            end
            default: begin
                if (d_byte == pcrc && (padr == my_id || padr == 8'hFF)) begin
                    case (ptyp)
                    CMD_JOB:    cmd_job  <= (plen == JOB_LEN);
                    CMD_STOP:   cmd_stop <= 1'b1;
                    CMD_SET_OT: if (plen != 16'd0) ot_thresh <= ot_stage;
                    CMD_PING:   cmd_ping <= 1'b1;
                    CMD_SET_TARGET: if (plen == 16'd32) target_be <= tgt_stage;
                    CMD_BIST:   cmd_bist <= (plen == 16'd0);
                    default: ;
                    endcase
                end
                pst <= P_SOF;
            end
            endcase
        end
    end

    // --------------------------------------------------- job control
    localparam [1:0] C_IDLE = 0, C_MID = 1, C_MIDW = 2, C_RUN = 3;
    reg [1:0]    cst;
    reg [1087:0] hdr_job;      // input bytes 0..135 (the chip owns 136..139)
    reg [7:0]    job_id;
    reg [23:0]   next_att;
    reg          job_req, stop_req;
    wire         sending_sol;  // a SOLUTION packet is on the wire

    reg [23:0]      lane_att  [0:LANES-1];
    reg [7:0]       lane_job  [0:LANES-1];   // job id of the lane's attempt
    reg [7:0]       done_job  [0:LANES-1];
    reg [LANES-1:0] lane_run;
    reg [LANES-1:0] done_pend;
    reg [23:0]      done_att  [0:LANES-1];
    reg [7:0]       done_nsol [0:LANES-1];
    reg [LANES-1:0] done_clr;  // from the packet builder

    genvar gl;
    generate
        for (gl = 0; gl < LANES; gl = gl + 1) begin : g_hdr
            assign hdr_eff[gl*1120 +: 1120] =
                {lane_att[gl][23:16], lane_att[gl][15:8], lane_att[gl][7:0], my_id, hdr_job};
        end
    endgenerate

    // lowest idle lane, if any
    // (each always block has its own loop variable: a shared one would be
    // one net driven from several processes)
    reg          have_idle;
    reg [LW-1:0] idle_lane;
    integer ii;
    always @* begin
        have_idle = 1'b0;
        idle_lane = 0;
        for (ii = LANES - 1; ii >= 0; ii = ii - 1)
            if (!lane_run[ii] && !done_pend[ii] && !lane_start[ii]) begin
                have_idle = 1'b1;
                idle_lane = ii[LW-1:0];
            end
    end

    wire mining_busy = (cst != C_IDLE) | (|lane_run);
    reg bist_running, bist_armed, bist_fault, bist_pending;
    wire bist_completed = bist_running && bist_armed && bist_done;
    wire busy = mining_busy | bist_running | bist_fault | bist_pending;
    // DONE is sticky in every bank. Require a low observation after this
    // request before accepting the next high as a completion. The lock is
    // acquired with START, including the bank's start-acknowledgment latency.
    always @(posedge clk) begin
        bist_start <= 1'b0;
        if (rst) begin
            bist_running <= 1'b0;
            bist_armed <= 1'b0;
            bist_fault <= 1'b0;
            bist_pending <= (HAS_BIST != 0 && BOOT_BIST != 0);
        end else if (bist_running) begin
            if (!bist_done) bist_armed <= 1'b1;
            if (bist_completed) begin
                bist_running <= 1'b0;
                bist_armed <= 1'b0;
                bist_fault <= bist_fail;
            end
        end else if (bist_pending) begin
            // Acquire ownership immediately after reset, before queued UART
            // jobs can dispatch. Sticky prior DONE still needs a fresh low.
            bist_start <= 1'b1;
            bist_running <= 1'b1;
            bist_armed <= 1'b0;
            bist_pending <= 1'b0;
        end else if (HAS_BIST != 0 && cmd_bist && !mining_busy && !job_req && !cmd_job
                     && !stop_req && !cmd_stop && !sending_sol && !(|lane_avail)) begin
            bist_start <= 1'b1;
            bist_running <= 1'b1;
            bist_armed <= 1'b0;
        end
    end
    integer li;

    always @(posedge clk) begin
        mid_start  <= 1'b0;
        lane_start <= {LANES{1'b0}};
        lane_abort <= 1'b0;
        done_pend  <= done_pend & ~done_clr;
        if (cmd_job && (!bist_fault || bist_running)) begin
            job_req <= 1'b1;
            stop_req <= 1'b0;
            hdr_job <= stage[1087:0];
            job_id  <= job_stage;
        end
        if (cmd_stop) begin stop_req <= 1'b1; job_req <= 1'b0; end
        for (li = 0; li < LANES; li = li + 1)
            if (lane_done[li]) begin
                lane_run[li]  <= 1'b0;
                done_pend[li] <= 1'b1;
                done_att[li]  <= lane_att[li];
                done_job[li]  <= lane_job[li];
                done_nsol[li] <= lane_nsol[li*8 +: 8];
            end
        if (rst) begin
            cst       <= C_IDLE;
            job_req   <= 1'b0;
            stop_req  <= 1'b0;
            lane_run  <= {LANES{1'b0}};
            done_pend <= {LANES{1'b0}};
        // JOB/STOP abort the lanes, which own the xbuf the builder may be
        // reading, so they wait for an in-flight SOLUTION packet to finish
        end else if (bist_completed && bist_fail) begin
            // Failed tables cannot serve queued or future work. A new BIST
            // can still be requested while the chip is quarantined.
            job_req <= 1'b0;
            stop_req <= 1'b0;
            lane_abort <= 1'b1;
            lane_run <= {LANES{1'b0}};
            done_pend <= {LANES{1'b0}};
            cst <= C_IDLE;
        end else if (stop_req && !cmd_job && !sending_sol) begin
            lane_abort <= 1'b1;
            lane_run   <= {LANES{1'b0}};
            stop_req   <= 1'b0;
            cst        <= C_IDLE;
        end else if (job_req && !cmd_job && !cmd_stop && !sending_sol
                     && !bist_pending && !bist_running && !bist_fault) begin
            lane_abort <= 1'b1;
            lane_run   <= {LANES{1'b0}};
            done_pend  <= {LANES{1'b0}};
            job_req    <= 1'b0;
            stop_req   <= 1'b0;
            next_att   <= 24'd0;
            cst        <= C_MID;
        end else if (!bist_pending && !bist_running && !bist_fault && !cmd_job && !cmd_stop) case (cst)
            C_MID:  begin mid_start <= 1'b1; cst <= C_MIDW; end
            C_MIDW: if (mid_done) cst <= C_RUN;
            C_RUN:  if (have_idle) begin
                lane_att[idle_lane]   <= next_att;
                lane_job[idle_lane]   <= job_id;
                lane_run[idle_lane]   <= 1'b1;
                lane_start[idle_lane] <= 1'b1;
                next_att              <= next_att + 1'b1;
            end
            default: ;
        endcase
    end

    // busy chain (active low toward the controller) and over-temp flag
    always @(posedge clk) begin
        if (rst) begin
            bo        <= 1'b1;
            temp_pull <= 1'b0;
        end else begin
            bo        <= bi_s[1] & ~busy;
            temp_pull <= (tsense >= ot_thresh);
        end
    end

    // ------------------------------------------- RI receive + buffer
    wire       u_valid;
    wire [7:0] u_byte;
    zeq_uart_rx #(.DIV(DIV)) u_rx_up (
        .clk(clk), .rst(rst), .rxd(ri), .valid(u_valid), .data(u_byte));

    wire             f_empty, f_full;
    wire [7:0]       f_head;
    wire [FIFO_AW:0] f_level;
    reg              f_pop;
    zeq_fifo #(.AW(FIFO_AW)) u_fifo (
        .clk(clk), .rst(rst), .push(u_valid), .din(u_byte), .full(f_full),
        .pop(f_pop), .empty(f_empty), .dout(f_head), .level(f_level));
    // room for a whole own packet's worth of arrivals, plus 1/64 slack
    localparam integer ROOM = (1 << (FIFO_AW - 1)) - (1 << (FIFO_AW - 6)) - 2;
    localparam [FIFO_AW:0] ROOM_C = ROOM[FIFO_AW:0];
    wire own_room = (f_level <= ROOM_C);

    // ---------------------------------------------- TX arbitration
    wire       tx_ready, uart_ready;
    reg        tx_valid;
    reg  [7:0] tx_byte;
    zeq_uart_tx #(.DIV(DIV)) u_tx (
        .clk(clk), .rst(rst), .valid(tx_valid), .data(tx_byte), .ready(uart_ready), .txd(ro));

    // Aggregate byte-rate quotas, from controller toward chain end:
    // full line, 3/4, 1/2, 1/4. Forwarded bytes consume the same quota as
    // local bytes. This prevents a tail chip from filling every preceding
    // FIFO above own_room forever. Inter-byte gaps preserve packet framing.
    // Eight extra clocks over an 8N1 frame include handshake/clock margin;
    // these are digital engineering limits, not analog oscillator signoff.
    localparam integer BYTE_BUDGET = 10 * DIV + 8;
    localparam integer PACE_W = $clog2(4 * BYTE_BUDGET + 1);
    localparam [PACE_W-1:0] PACE_1 = PACE_W'((4 * BYTE_BUDGET + 2) / 3);
    localparam [PACE_W-1:0] PACE_2 = PACE_W'(2 * BYTE_BUDGET);
    localparam [PACE_W-1:0] PACE_3 = PACE_W'(4 * BYTE_BUDGET);
    reg [PACE_W-1:0] pace_wait;
    assign tx_ready = uart_ready && pace_wait == 0;
    always @(posedge clk) begin
        if (rst) pace_wait <= 0;
        else if (tx_valid && uart_ready) begin
            case (addr_strap)
                2'd0: pace_wait <= 0;
                2'd1: pace_wait <= PACE_1;
                2'd2: pace_wait <= PACE_2;
                default: pace_wait <= PACE_3;
            endcase
        end else if (pace_wait != 0) pace_wait <= pace_wait - 1'b1;
    end

    localparam [1:0] A_IDLE = 0, A_FWD = 1, A_OWN = 2;
    reg [1:0]  ast;
    reg        own_turn;   // round-robin: own packet goes next if waiting
    reg [15:0] fidx, flen;
    localparam integer FWD_GAP_LIMIT = 32 * BYTE_BUDGET;
    localparam integer FWD_GAP_W = $clog2(FWD_GAP_LIMIT + 1);
    reg [FWD_GAP_W-1:0] fwd_gap;
    wire forward_timeout = ast == A_FWD && f_empty &&
                           fwd_gap == FWD_GAP_W'(FWD_GAP_LIMIT - 1);
    always @(posedge clk) begin
        if (rst || ast != A_FWD || !f_empty) fwd_gap <= 0;
        else if (!forward_timeout) fwd_gap <= fwd_gap + 1'b1;
    end

    // own-packet builder
    localparam [2:0] B_IDLE = 0, B_EMIT = 1, B_F0 = 2, B_F1 = 3, B_F2 = 4, B_END = 5;
    reg [2:0]       bst;
    reg [7:0]       btyp, bjob;
    reg [15:0]      blen, bidx;    // bidx counts from the SOF byte
    reg [7:0]       bcrc;
    reg [23:0]      batt;
    reg [7:0]       bnsol;
    reg [LW-1:0]    bsel;          // lane this packet belongs to
    reg [31:0]      bword;
    reg             bword_ok;
    reg [LANES-1:0] sol_taken;
    reg             pong_pend;

    // A pending JOB/STOP aborts the lanes as soon as no SOLUTION is on the
    // wire. sending_sol only rises the cycle after the builder commits to a
    // packet, so a builder choosing a solution in the cycle the abort fires
    // (or the one after, while lane_avail has not yet fallen) would read an
    // aborted xbuf and transmit stale words. Start no new SOLUTION once an
    // abort is requested; one already on the wire still finishes first.
    wire         sol_hold = job_req || stop_req || lane_abort ||
                            (bist_completed && bist_fail);

    // pick a lane: lowest pending DONE, else lowest untaken solution
    reg          have_done, have_sol;
    reg [LW-1:0] done_lane, sol_lane;
    integer pi;
    always @* begin
        have_done = 1'b0; done_lane = 0;
        have_sol  = 1'b0; sol_lane  = 0;
        for (pi = LANES - 1; pi >= 0; pi = pi - 1) begin
            if (done_pend[pi] && !done_clr[pi]) begin have_done = 1'b1; done_lane = pi[LW-1:0]; end
            if (lane_avail[pi] && !sol_taken[pi] && !sol_hold) begin have_sol = 1'b1; sol_lane = pi[LW-1:0]; end
        end
    end
    wire own_has = (pong_pend | have_done | have_sol) & own_room;
    assign sending_sol = (bst != B_IDLE) && (btyp == RSP_SOL);

    wire [15:0]   btotal    = blen + 16'd6;
    wire [15:0]   pidx      = bidx - 16'd5;          // payload byte index
    wire [15:0]   widx      = (pidx - 16'd4) >> 2;   // solution word index
    wire [1:0]    wbyte     = pidx[1:0];             // byte within the BE word
    wire [1:0]    abyte     = pidx[1:0] - 2'd1;      // attempt byte (pidx 1..3)
    wire [RW-1:0] sel_rdata = lane_rdata[bsel * RW +: RW];

    reg [7:0] bcur;
    always @* begin
        if (bidx == 16'd0)      bcur = UP_SOF;
        else if (bidx == 16'd1) bcur = btyp;
        else if (bidx == 16'd2) bcur = my_id;
        else if (bidx == 16'd3) bcur = blen[7:0];
        else if (bidx == 16'd4) bcur = blen[15:8];
        else if (bidx == btotal - 1'b1) bcur = bcrc;
        else if (btyp == RSP_PONG) begin
            case (pidx[1:0])
                2'd0: bcur = VERSION;
                2'd1: bcur = {4'd0, (HAS_BIST != 0 && !bist_pending && !bist_running && bist_fail),
                             (HAS_BIST != 0 && !bist_pending && !bist_running && bist_done), busy, temp_pull};
                2'd2: bcur = tsense;
                default: bcur = LANES_B;
            endcase
        end else if (pidx == 16'd0) bcur = bjob;
        else if (pidx < 16'd4) bcur = batt[8 * abyte +: 8];
        else if (btyp == RSP_DONE) bcur = bnsol;
        else bcur = bword[31 - 8 * wbyte -: 8];
    end
    wire need_word = (btyp == RSP_SOL) && (bidx >= 16'd9) && (bidx != btotal - 1'b1)
                     && (wbyte == 2'd0) && !bword_ok;

    always @(posedge clk) begin
        lane_ack  <= {LANES{1'b0}};
        done_clr  <= {LANES{1'b0}};
        f_pop     <= 1'b0;
        sol_taken <= sol_taken & lane_avail;
        if (cmd_ping) pong_pend <= 1'b1;
        if (rst) begin
            ast       <= A_IDLE;
            bst       <= B_IDLE;
            own_turn  <= 1'b1;
            tx_valid  <= 1'b0;
            sol_taken <= {LANES{1'b0}};
            pong_pend <= 1'b0;
        end else begin
            tx_valid <= 1'b0;
            if (forward_timeout) begin
                ast <= A_IDLE;
                fidx <= 0;
                flen <= 0;
            end else case (ast)
            // f_pop is registered: on the cycle after the last forwarded
            // byte, the FIFO still presents that byte until this edge.
            // Wait for the pop to retire before selecting another packet.
            A_IDLE: if (!f_pop) begin
                if (!f_empty && !(own_turn && own_has && bst == B_IDLE)) begin
                    fidx     <= 0;
                    own_turn <= 1'b1;
                    ast      <= A_FWD;
                end else if (own_has && bst == B_IDLE) begin
                    own_turn <= 1'b0;
                    // one packet: PONG, then DONE, then SOLUTION
                    bidx     <= 0;
                    bcrc     <= 8'd0;
                    bword_ok <= 1'b0;
                    if (pong_pend) begin
                        btyp <= RSP_PONG; blen <= 16'd4;
                    end else if (have_done) begin
                        btyp  <= RSP_DONE; blen <= 16'd5;
                        bjob  <= done_job[done_lane];
                        bsel  <= done_lane;
                        batt  <= done_att[done_lane];
                        bnsol <= done_nsol[done_lane];
                    end else begin
                        btyp <= RSP_SOL; blen <= SOL_LEN;
                        bjob <= lane_job[sol_lane];
                        bsel <= sol_lane;
                        batt <= lane_att[sol_lane];
                        sol_taken[sol_lane] <= 1'b1;
                    end
                    bst <= B_EMIT;
                    ast <= A_OWN;
                end
            end

            // forward one whole packet from RI
            A_FWD: if (!f_empty && tx_ready && !tx_valid && !f_pop) begin
                f_pop <= 1'b1;
                if (fidx == 0 && f_head != UP_SOF) begin
                    ast <= A_IDLE;   // not a packet start: drop it and resync
                end else begin
                    tx_valid <= 1'b1;
                    tx_byte  <= f_head;
                    fidx     <= fidx + 1'b1;
                    if (fidx == 16'd3) flen[7:0]  <= f_head;
                    if (fidx == 16'd4) begin
                        flen[15:8] <= f_head;
                        // All generated response payloads fit SOL_LEN. This
                        // also prevents the 16-bit end-index addition wrapping.
                        if ({f_head, flen[7:0]} > SOL_LEN) ast <= A_IDLE;
                    end
                    if (fidx >= 16'd5 && fidx == flen + 16'd5) ast <= A_IDLE;
                end
            end

            // this chip's packet
            default: case (bst)
                B_EMIT: if (need_word) begin
                    sol_raddr <= widx[K-1:0];
                    bst       <= B_F0;
                end else if (tx_ready && !tx_valid) begin
                    tx_valid <= 1'b1;
                    tx_byte  <= bcur;
                    if (bidx != 16'd0 && bidx != btotal - 1'b1) bcrc <= crc8(bcrc, bcur);
                    if (btyp == RSP_SOL && bidx >= 16'd9 && wbyte == 2'd3) bword_ok <= 1'b0;
                    bidx <= bidx + 1'b1;
                    if (bidx == btotal - 1'b1) bst <= B_END;
                end
                B_F0: bst <= B_F1;             // address reaches xbuf
                B_F1: bst <= B_F2;             // registered read
                B_F2: begin
                    bword    <= {{(32-RW){1'b0}}, sel_rdata};
                    bword_ok <= 1'b1;
                    bst      <= B_EMIT;
                end
                B_END: begin
                    if (btyp == RSP_PONG) pong_pend <= 1'b0;
                    else if (btyp == RSP_DONE) done_clr[bsel] <= 1'b1;
                    else lane_ack[bsel] <= 1'b1;
                    bst <= B_IDLE;
                    ast <= A_IDLE;
                end
                default: begin bst <= B_IDLE; ast <= A_IDLE; end
            endcase
            endcase
        end
    end
endmodule

`default_nettype wire
