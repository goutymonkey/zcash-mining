// Equihash leaf hash: Blake2b-(8*HOUT) personalized "ZcashPoW"||N||K over
// header140 || le32(g).
//
// The 144-byte message is two blocks. Block 0 (header bytes 0..127) is the
// same for every g, so it is compressed once per job into a midstate; each
// hash request then only runs block 1 (header bytes 128..139, g, zero pad).
// That halves the hashing work, the same trick commercial Equihash
// ASICs use.
`default_nettype none

module zeq_eh_hash #(
    parameter integer N = 48,
    parameter integer K = 5,
    parameter integer SPLIT = 1,   // G steps per cycle, see zeq_blake2b
    // derived (do not override)
    parameter integer IPHO = 512 / N,
    parameter integer HOUT = IPHO * N / 8
) (
    input  wire              clk,
    input  wire              rst,
    input  wire [1119:0]     hdr,        // byte i at [8i+:8]
    input  wire              mid_start,  // compress block 0 into the midstate
    output reg               mid_done,
    input  wire              hash_start, // hash leaf group g (hdr, g held until done)
    input  wire              flush,      // forget any hash in flight
    input  wire [31:0]       g,
    output reg               hash_done,
    output wire [8*HOUT-1:0] dig         // digest byte j at [8j+:8]
);
    localparam [63:0] IV0 = 64'h6a09e667f3bcc908;
    localparam [63:0] IV1 = 64'hbb67ae8584caa73b;
    localparam [63:0] IV2 = 64'h3c6ef372fe94f82b;
    localparam [63:0] IV3 = 64'ha54ff53a5f1d36f1;
    localparam [63:0] IV4 = 64'h510e527fade682d1;
    localparam [63:0] IV5 = 64'h9b05688c2b3e6c1f;
    localparam [63:0] IV6 = 64'h1f83d9abfb41bd6b;
    localparam [63:0] IV7 = 64'h5be0cd19137e2179;

    // parameter block: digest length, key 0, fanout 1, depth 1;
    // personalization "ZcashPoW" || le32(N) || le32(K) in words 6..7
    localparam [31:0] HOUT32  = HOUT;
    localparam [31:0] N32     = N;
    localparam [31:0] K32     = K;
    localparam [63:0] P0      = {32'd0, 8'd1, 8'd1, HOUT32[15:0]};
    localparam [63:0] PERS_LO = 64'h576f50687361635a;  // "ZcashPoW" LE
    localparam [63:0] PERS_HI = {K32, N32};
    localparam [511:0] H0 = {
        IV7 ^ PERS_HI, IV6 ^ PERS_LO, IV5, IV4, IV3, IV2, IV1, IV0 ^ P0
    };

    reg  [511:0] mid;
    reg          which;  // 0 = midstate job, 1 = leaf hash
    reg          go;
    reg          pend;   // a leaf hash was requested and not yet reported
    wire         cdone;
    wire [511:0] hout;

    wire [1023:0] block0 = hdr[1023:0];
    wire [1023:0] block1 = {896'd0, g, hdr[1119:1024]};

    zeq_blake2b #(.SPLIT(SPLIT)) u_core (
        .clk  (clk),
        .rst  (rst),
        .start(go),
        .h_in (which ? mid : H0),
        .m    (which ? block1 : block0),
        .t    (which ? 64'd144 : 64'd128),
        .last (which),
        .done (cdone),
        .h_out(hout)
    );

    assign dig = hout[8*HOUT-1:0];

    always @(posedge clk) begin
        go        <= 1'b0;
        mid_done  <= 1'b0;
        hash_done <= 1'b0;
        if (rst) begin
            which <= 1'b0;
            pend  <= 1'b0;
        end else begin
            // a completion in the same cycle as a new request (or after an
            // abort) belongs to an abandoned hash and is not reported
            if (cdone) begin
                if (which) begin
                    if (pend && !hash_start && !flush) hash_done <= 1'b1;
                    pend <= 1'b0;
                end else begin
                    mid      <= hout;
                    mid_done <= 1'b1;
                end
            end
            if (flush) pend <= 1'b0;
            if (mid_start) begin
                which <= 1'b0;
                go    <= 1'b1;
            end else if (hash_start) begin
                which <= 1'b1;
                go    <= 1'b1;
                pend  <= 1'b1;
            end
        end
    end
endmodule

`default_nettype wire
