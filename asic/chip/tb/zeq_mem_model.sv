// Behavioral table memory behind a solver port, pipelined like a DRAM
// controller: a request can be accepted every cycle, reads return in
// order no sooner than LAT cycles later, and STALL_PCT adds random
// backpressure (req_ready low) and random extra read delay. Responses
// cannot be refused, so the solver must reserve buffer space before
// issuing reads.
/* verilator lint_off BLKSEQ */
module zeq_mem_model #(
    parameter integer AW = 10,
    parameter integer DW = 32,
    parameter integer DEPTH = 1 << AW,
    parameter integer LAT = 1,        // min cycles from accept to rsp
    parameter integer STALL_PCT = 0,  // % stalls (backpressure and delay)
    parameter integer SEED = 1,
    parameter integer QD = 64         // max reads in flight
) (
    input  wire          clk,
    input  wire          req_valid,
    output reg           req_ready,
    input  wire          req_we,
    input  wire [AW-1:0] req_addr,
    input  wire [DW-1:0] req_wdata,
    output reg           rsp_valid,
    output reg  [DW-1:0] rsp_rdata
);
    reg [DW-1:0] mem [0:DEPTH-1];
    integer      rng = SEED;
    longint      now = 0;

    // in-flight reads: data captured at accept time (in-order memory)
    reg [DW-1:0] q_data [0:QD-1];
    longint      q_due  [0:QD-1];
    integer      q_head = 0, q_tail = 0, q_cnt = 0;
    longint      last_due = 0;

    function automatic integer rnd100();
        rng = rng * 1103515245 + 12345;
        rnd100 = ((rng >>> 16) & 32'h7fff) % 100;
    endfunction

    initial begin
        req_ready = 1;
        rsp_valid = 0;
    end

    always @(posedge clk) begin
        longint due;
        now <= now + 1;
        rsp_valid <= 1'b0;
        if (q_cnt > 0 && q_due[q_head] <= now) begin
            rsp_valid <= 1'b1;
            rsp_rdata <= q_data[q_head];
            q_head = (q_head + 1) % QD;
            q_cnt  = q_cnt - 1;
        end
        if (req_valid && req_ready) begin
            if (req_we) mem[req_addr] <= req_wdata;
            else begin
                due = now + longint'(LAT) - 1;
                if (STALL_PCT > 0 && rnd100() < STALL_PCT) due = due + 3;
                if (due <= last_due) due = last_due + 1;   // keep order
                last_due = due;
                q_data[q_tail] = mem[req_addr];
                q_due[q_tail]  = due;
                q_tail = (q_tail + 1) % QD;
                q_cnt  = q_cnt + 1;
            end
        end
        req_ready <= (q_cnt < QD - 2) && ((STALL_PCT == 0) || (rnd100() >= STALL_PCT));
    end
endmodule
/* verilator lint_on BLKSEQ */
