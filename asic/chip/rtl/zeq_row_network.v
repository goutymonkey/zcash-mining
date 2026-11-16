// Two-stage row transport. Producers hold valid/target/data until in_take.
// Each output bank accepts one row every cycle out_valid is high. Output
// backpressure is intentionally absent: solver banks always consume or drop
// a full-bucket row. Reset/cancel flush all buffered rows; idle is used by the
// solver's round barrier so buffered rows cannot cross a round boundary.
`default_nettype none
module zeq_row_network #(
    parameter integer PB=4, DW=232,
    parameter integer SB=PB/2, GB=PB-SB
) (
    input wire clk, rst, cancel,
    input wire [(1<<PB)-1:0] in_valid,
    input wire [(1<<PB)*PB-1:0] in_target,
    input wire [(1<<PB)*DW-1:0] in_data,
    output wire [(1<<PB)-1:0] in_take,
    output wire [(1<<PB)-1:0] out_valid,
    output wire [(1<<PB)*DW-1:0] out_data,
    output wire idle
`ifdef NETWORK_PROOF
    ,output wire [(1<<GB)*(1<<GB)-1:0] proof_valid
    ,output wire [(1<<GB)*(1<<GB)*DW-1:0] proof_data
    ,output wire [(1<<GB)*(1<<GB)*SB-1:0] proof_target
    ,output wire [(1<<PB)*GB-1:0] proof_rr
`endif
);
    localparam integer P=1<<PB, S=1<<SB, G=1<<GB;
    // Contiguous source groups of S engines, destination groups of S banks.
    // One independent elastic register per source-group/destination-group.
    wire [G*G-1:0] valid, take;
    wire [DW-1:0] data [0:G*G-1];
    wire [SB-1:0] target [0:G*G-1];
    wire [G*S*G-1:0] granted;
    wire clear = rst || cancel;
    assign idle = ~(|valid);
    genvar src_group, dst_group, local_src, local_dst, src;
    generate
        for(src_group=0;src_group<G;src_group=src_group+1) begin : g_source
            wire [S*GB-1:0] group_targets;
            for(local_src=0;local_src<S;local_src=local_src+1) begin : g_target
                assign group_targets[local_src*GB +: GB] =
                    in_target[(src_group*S+local_src)*PB+SB +: GB];
                wire [G-1:0] accepted;
                for(dst_group=0;dst_group<G;dst_group=dst_group+1) begin : g_accept
                    assign accepted[dst_group] = granted[(src_group*S+local_src)*G+dst_group];
                end
                assign in_take[src_group*S+local_src] = |accepted;
            end
            for(dst_group=0;dst_group<G;dst_group=dst_group+1) begin : g_link
                localparam integer LINK=src_group*G+dst_group;
                reg occupied;
                reg [DW-1:0] payload;
                reg [SB-1:0] bank;
                wire room = !occupied || take[LINK];
                wire selected;
                wire [SB-1:0] winner;
                zeq_xbar_arb #(.PB(SB),.TB(GB),.BANK(dst_group)) u_arb (
                    .clk(clk),.rst(clear),
                    .req(in_valid[src_group*S +: S] & {S{room && !clear}}),
                    .tgt(group_targets),.gv(selected),.gsel(winner));
                assign valid[LINK] = occupied && !clear;
                assign data[LINK] = payload;
                assign target[LINK] = bank;
`ifdef NETWORK_PROOF
                assign proof_valid[LINK]=valid[LINK];
                assign proof_data[LINK*DW +: DW]=payload;
                assign proof_target[LINK*SB +: SB]=bank;
`endif
                for(local_src=0;local_src<S;local_src=local_src+1) begin : g_grant
                    assign granted[(src_group*S+local_src)*G+dst_group] = selected && winner==local_src[SB-1:0];
                end
                always @(posedge clk) begin
                    if(clear) occupied<=0;
                    else if(room) begin
                        occupied<=selected;
                        if(selected) begin
                            payload<=in_data[(src_group*S+32'(winner))*DW +: DW];
                            bank<=in_target[(src_group*S+32'(winner))*PB +: SB];
                        end
                    end
                end
            end
        end
        for(dst_group=0;dst_group<G;dst_group=dst_group+1) begin : g_destination
            wire [G-1:0] requests;
            wire [G*SB-1:0] banks;
            wire [G*DW-1:0] payloads;
            wire [S*G-1:0] consumed;
            for(src=0;src<G;src=src+1) begin : g_input
                assign requests[src] = valid[src*G+dst_group];
                assign banks[src*SB +: SB] = target[src*G+dst_group];
                assign payloads[src*DW +: DW] = data[src*G+dst_group];
                wire [S-1:0] accepted;
                for(local_dst=0;local_dst<S;local_dst=local_dst+1) begin : g_accepted
                    assign accepted[local_dst]=consumed[local_dst*G+src];
                end
                assign take[src*G+dst_group]=|accepted;
            end
            for(local_dst=0;local_dst<S;local_dst=local_dst+1) begin : g_bank
                localparam integer BANK=dst_group*S+local_dst;
                wire selected;
                wire [GB-1:0] winner;
                zeq_xbar_arb #(.PB(GB),.TB(SB),.BANK(local_dst)) u_arb (
                    .clk(clk),.rst(clear),.req(requests),.tgt(banks),.gv(selected),.gsel(winner)
`ifdef NETWORK_PROOF
                    ,.proof_rr(proof_rr[BANK*GB +: GB])
`endif
                );
                assign out_valid[BANK]=selected;
                assign out_data[BANK*DW +: DW]=payloads[winner*DW +: DW];
                for(src=0;src<G;src=src+1) begin : g_take
                    assign consumed[local_dst*G+src]=selected && winner==src[GB-1:0];
                end
            end
        end
    endgenerate
`ifndef SYNTHESIS
    initial if(PB<2 || SB<1 || GB<1 || SB+GB!=PB) $fatal(1,"invalid staged network grouping");
`endif
endmodule
// Queued crossbar (STAGED_NETWORK = 2). Each bank accepts up to two rows per
// cycle into a small FIFO and writes one per cycle, so two producers that
// pick the same bank in one cycle no longer block each other. A full
// crossbar with one grant per bank saturates near 0.6 rows per bank-cycle
// under uniform traffic; the queue removes most of that loss.
// Same interface and idle/flush behaviour as zeq_row_network.
module zeq_row_queue #(
    parameter integer PB=4, DW=232, DEPTH=4,
    parameter integer SRCB=PB      // log2 producers (2^PB banks)
) (
    input wire clk, rst, cancel,
    input wire [(1<<SRCB)-1:0] in_valid,
    input wire [(1<<SRCB)*PB-1:0] in_target,
    input wire [(1<<SRCB)*DW-1:0] in_data,
    output wire [(1<<SRCB)-1:0] in_take,
    output wire [(1<<PB)-1:0] out_valid,
    output wire [(1<<PB)*DW-1:0] out_data,
    output wire idle
);
    localparam integer P=1<<PB;
    localparam integer NS=1<<SRCB;
    localparam integer AB=$clog2(DEPTH);
    localparam [AB:0] DEPTH_C=DEPTH[AB:0];
    wire clear = rst || cancel;
    wire [P*NS-1:0] took;           // [bank*NS + source]
    wire [P-1:0] empty;
    assign idle = &empty;
    genvar bank, src;
    generate
        for(src=0;src<NS;src=src+1) begin : g_take
            wire [P-1:0] by_bank;
            for(bank=0;bank<P;bank=bank+1) begin : g_bank
                assign by_bank[bank]=took[bank*NS+src];
            end
            assign in_take[src]=|by_bank;
        end
        for(bank=0;bank<P;bank=bank+1) begin : g_queue
            reg [DW-1:0] mem [0:DEPTH-1];
            reg [AB-1:0] wp, rp;
            reg [AB:0] count;
            wire room1 = count < DEPTH_C;
            wire room2 = count < DEPTH_C - 1'b1;
            wire g1, g2;
            wire [SRCB-1:0] s1, s2;
            wire [NS-1:0] first;
            for(src=0;src<NS;src=src+1) begin : g_first
                assign first[src] = g1 && s1==src[SRCB-1:0];
                assign took[bank*NS+src] = first[src] || (g2 && s2==src[SRCB-1:0]);
            end
            zeq_xbar_arb #(.PB(SRCB),.TB(PB),.BANK(bank)) u_arb1 (
                .clk(clk),.rst(clear),.req(in_valid & {NS{room1 && !clear}}),
                .tgt(in_target),.gv(g1),.gsel(s1));
            zeq_xbar_arb #(.PB(SRCB),.TB(PB),.BANK(bank)) u_arb2 (
                .clk(clk),.rst(clear),.req(in_valid & ~first & {NS{room2 && !clear}}),
                .tgt(in_target),.gv(g2),.gsel(s2));
            wire pop = count != 0;
            wire [AB-1:0] wp1 = (wp == DEPTH_C[AB-1:0] - 1'b1) ? {AB{1'b0}} : wp + 1'b1;
            wire [AB-1:0] wp2 = (wp1 == DEPTH_C[AB-1:0] - 1'b1) ? {AB{1'b0}} : wp1 + 1'b1;
            assign empty[bank] = !pop;
            assign out_valid[bank] = pop && !clear;
            assign out_data[bank*DW +: DW] = mem[rp];
            always @(posedge clk) begin
                if(clear) begin
                    wp<=0; rp<=0; count<=0;
                end else begin
                    if(g1) mem[wp]<=in_data[32'(s1)*DW +: DW];
                    if(g2) mem[wp1]<=in_data[32'(s2)*DW +: DW];
                    wp <= g2 ? wp2 : (g1 ? wp1 : wp);
                    if(pop) rp <= (rp == DEPTH_C[AB-1:0] - 1'b1) ? {AB{1'b0}} : rp + 1'b1;
                    count <= count + {{AB{1'b0}},g1} + {{AB{1'b0}},g2} - {{AB{1'b0}},pop};
                end
            end
        end
    endgenerate
`ifndef SYNTHESIS
    initial if(PB<1 || SRCB<PB || DEPTH<2 || (DEPTH & (DEPTH-1))!=0) $fatal(1,"invalid row queue");
`endif
endmodule
`default_nettype wire
