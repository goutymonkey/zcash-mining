// Lifetime-packed row values and parent pointers, with one-cycle reads.
// A row loses CB payload bits per round. Each parity is split into PW-bit
// RAM slices: values occupy low slices, retained parents grow from the top.
// Independent slices permit final-round value reads and tree expansion
// concurrently without requiring a second read port on any SRAM macro.
`default_nettype none
module zeq_packed_values #(
    parameter integer N = 48, K = 5, PW = 16, AW = 8,
    parameter integer DEPTH = 1 << AW,
    parameter integer CB = N / (K+1), VW = N-CB, LW = $clog2(K+1)
) (
    input wire clk, rst,
    input wire [LW-1:0] phase,
    input wire we,
    input wire [AW-1:0] waddr,
    input wire [VW-1:0] wvalue,
    input wire [PW-1:0] wparent,
    input wire re,
    input wire [AW-1:0] raddr,
    output wire [VW-1:0] rvalue,
    input wire pre,
    input wire [LW-1:0] plevel,
    input wire [AW-1:0] paddr,
    output wire [PW-1:0] pvalue,
    input wire bist_start,
    output wire bist_done, bist_fail
`ifdef PACKED_PROOF
    ,output wire [K*DEPTH*VW-1:0] proof_values
    ,output wire [K*DEPTH*PW-1:0] proof_parents
    ,output wire proof_bist_active
`endif
);
    function integer slice_count;
        integer level, needed, peak;
        begin
            peak = 0;
            for (level = 0; level < K; level = level + 1) begin
                needed = (N-(level+1)*CB+PW-1)/PW + (level+1)/2;
                if (needed > peak) peak = needed;
            end
            slice_count = peak;
        end
    endfunction
    localparam integer SLICES = slice_count();
    localparam integer TOTAL = SLICES * PW;
    localparam integer SA = $clog2(SLICES);
    wire [TOTAL-1:0] padded_value = {{(TOTAL-VW){1'b0}}, wvalue};
    wire [2*TOTAL-1:0] q;
    wire [2*SLICES-1:0] bd, bf;
`ifdef PACKED_PROOF
    wire [2*SLICES*DEPTH*PW-1:0] proof_storage;
    wire [2*SLICES-1:0] proof_bist_states;
    assign proof_bist_active=|proof_bist_states;
    genvar level, row, payload_bit;
    generate for(level=0;level<K;level=level+1) begin : g_proof_level
        for(row=0;row<DEPTH;row=row+1) begin : g_row
            for(payload_bit=0;payload_bit<VW;payload_bit=payload_bit+1) begin : g_bit
                if(payload_bit<N-(level+1)*CB)
                    assign proof_values[(level*DEPTH+row)*VW+payload_bit]=
                        proof_storage[((level%2)*SLICES+payload_bit/PW)*DEPTH*PW+row*PW+payload_bit%PW];
                else assign proof_values[(level*DEPTH+row)*VW+payload_bit]=1'b0;
            end
            if(level!=0)
                assign proof_parents[(level*DEPTH+row)*PW +: PW]=
                    proof_storage[((level%2)*SLICES+SLICES-(level+1)/2)*DEPTH*PW+row*PW +: PW];
            else assign proof_parents[(level*DEPTH+row)*PW +: PW]=0;
        end
    end endgenerate
`endif
    assign bist_done = &bd;
    assign bist_fail = |bf;
    wire [31:0] write_bits = N - (32'(phase)+1)*CB;
    wire [31:0] read_bits = N - 32'(phase)*CB;
    wire [31:0] write_parent_slice = SLICES - (32'(phase)+1)/2;
    wire [31:0] read_parent_slice = SLICES - (32'(plevel)+1)/2;
    reg read_parity_q, parent_parity_q;
    reg [LW-1:0] read_phase_q;
    reg [SA-1:0] parent_slice_q;
    always @(posedge clk) begin
        if (rst) begin
            read_parity_q <= 0; parent_parity_q <= 0;
            read_phase_q <= 1; parent_slice_q <= 0;
        end else begin
            if (re) begin read_parity_q <= ~phase[0]; read_phase_q <= phase; end
            if (pre) begin parent_parity_q <= plevel[0]; parent_slice_q <= read_parent_slice[SA-1:0]; end
        end
    end
    assign pvalue = q[(32'(parent_parity_q)*SLICES + 32'(parent_slice_q))*PW +: PW];
    genvar parity, slice, bit_i;
    generate
        for (bit_i=0; bit_i<VW; bit_i=bit_i+1) begin : g_output
            // Constant thresholds clear old pointer bits above the live value.
            assign rvalue[bit_i] = (32'(read_phase_q) <= (N-1-bit_i)/CB)
                ? q[32'(read_parity_q)*TOTAL+bit_i] : 1'b0;
        end
        for (parity=0; parity<2; parity=parity+1) begin : g_parity
            for (slice=0; slice<SLICES; slice=slice+1) begin : g_slice
                wire write_pointer = phase != 0 && write_parent_slice == slice;
                wire write_value = slice*PW < write_bits;
                wire wr = we && phase[0] == parity[0] && (write_pointer || write_value);
                wire vr = re && ~phase[0] == parity[0] && slice*PW < read_bits;
                wire pr = pre && plevel[0] == parity[0] && read_parent_slice == slice;
                wire [PW-1:0] wd = write_pointer ? wparent : padded_value[slice*PW +: PW];
                zeq_ram #(.AW(AW), .DW(PW), .DEPTH(DEPTH)) m_slice (
                    .clk(clk), .rst(rst), .we(wr), .waddr(waddr), .wdata(wd),
                    .re(vr || pr), .raddr(pr ? paddr : raddr),
                    .rdata(q[(parity*SLICES+slice)*PW +: PW]),
                    .bist_start(bist_start), .bist_done(bd[parity*SLICES+slice]),
                    .bist_fail(bf[parity*SLICES+slice])
`ifdef PACKED_PROOF
                    ,.proof_mem(proof_storage[(parity*SLICES+slice)*DEPTH*PW +: DEPTH*PW])
                    ,.proof_bist_active(proof_bist_states[parity*SLICES+slice])
`endif
                );
`ifndef SYNTHESIS
                always @(posedge clk) if (!rst) begin
                    if (vr && pr && raddr != paddr) $fatal(1, "packed-table read-port collision");
                    if (we && write_pointer && write_value) $fatal(1, "packed-table live-value/parent overlap");
                end
`endif
            end
        end
    endgenerate
`ifndef SYNTHESIS
    always @(posedge clk) if (!rst) begin
        if (we && 32'(phase) >= K) $fatal(1, "packed-table write phase invalid");
        if (re && (phase == 0 || 32'(phase) > K)) $fatal(1, "packed-table read phase invalid");
        if (pre && (plevel == 0 || 32'(plevel) >= K || 32'(phase) != K))
            $fatal(1, "packed-table expansion phase invalid");
    end
`endif
endmodule
`default_nettype wire
