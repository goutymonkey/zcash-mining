// Local synchronous-read contract, NOT a full-solver equivalence proof.
// Both memories see the same address/data on useful reads. Extra reads have
// no write side effects, and registered outputs hold while read-enable is low.
// enter/leave abstract bucket transitions; va abstracts arbitrary upstream
// valid traffic. hold_c is arbitrary, including indefinitely long stalls.
module read_gating_contract #(
    parameter integer DW = 188,
    parameter integer MUTANT = 0
) (
    input wire clk, rst, enter, leave, hold_c, va,
    input wire [DW-1:0] sample
);
    reg active = 0;
    reg vb = 0, vc = 0;
    wire [3:0] es = active ? 4'd9 : 4'd4;
    localparam [3:0] E_WK = 9;
    localparam integer GROUP_REPLAY = 0;
    wire replay_order_pending = 0;
    wire reference_read;
    wire candidate_read;
    // The qualification runner inserts the exact RTL read-enable expressions.
    `include "read_expressions.vh"
    wire checked_read = MUTANT == 1 ? reference_read && va :
                        MUTANT == 2 ? active && vb : candidate_read;
    reg [DW-1:0] old_q, new_q;
    always @(posedge clk) begin
        if (reference_read) old_q <= sample;
        if (checked_read) new_q <= sample;
        if (rst || leave) begin
            active <= 0; vb <= 0; vc <= 0;
        end else if (enter) begin
            active <= 1; vb <= 0; vc <= 0;
        end else if (active && !hold_c) begin
            vc <= vb;
            vb <= va;
        end
        if (active && vc) assert(old_q == new_q);
    end
endmodule
