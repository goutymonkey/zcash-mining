// On-chip share filter, one per lane, between the solver and the link.
//
// For each solution the solver offers, compute the Zcash block hash
//   SHA256(SHA256(header140 || CompactSize(S) || minimal_solution))
// where minimal_solution packs the 2^K indices big-endian at CB+1 bits each
// (S = 2^K (CB+1) / 8 bytes: 36 at (48,5), 1344 at (200,9)), and forward
// the solution to the link only if the hash, read as a little-endian
// number, is <= the pool target (big-endian bytes, set by SET_TARGET).
// Solutions that miss the target are dropped here, so only shares use the
// chain. The default target (all ones) passes everything.
`default_nettype none

module zeq_share #(
    parameter integer N = 48,
    parameter integer K = 5,
    // derived (do not override)
    parameter integer CB   = N / (K + 1),
    parameter integer RW   = CB + 2,
    parameter integer NSOL = 1 << K
) (
    input  wire          clk,
    input  wire          rst,
    input  wire          cancel,
    input  wire [1119:0] hdr,         // this lane's input, byte i at [8i+:8]
    input  wire [255:0]  target_be,   // byte 0 (most significant) at [255:248]
    // solver side
    input  wire          s_avail,
    output reg           s_ack,
    output wire [K-1:0]  s_raddr,
    input  wire [RW-1:0] s_rdata,
    // link side
    output reg           l_avail,
    input  wire          l_ack,
    input  wire [K-1:0]  l_raddr,
    output wire [RW-1:0] l_rdata,
    output reg  [15:0]   dropped      // solutions filtered out (wraps)
);
    localparam integer IW  = CB + 1;                    // packed index bits
    localparam integer S   = NSOL * IW / 8;             // solution bytes
    localparam integer PFX = (S < 253) ? 1 : 3;         // CompactSize length
    localparam integer L   = 140 + PFX + S;             // message bytes
    localparam integer P   = ((L + 9 + 63) / 64) * 64;  // padded length
    localparam [63:0]  LBITS = L * 8;
    localparam [15:0]  S16   = S[15:0];
    localparam [15:0]  L16   = L[15:0];
    localparam [15:0]  P16   = P[15:0];
    localparam [15:0]  SOL0  = 16'd140 + PFX[15:0];      // first solution byte
    localparam [255:0] IV = {32'h6a09e667, 32'hbb67ae85, 32'h3c6ef372, 32'ha54ff53a,
                             32'h510e527f, 32'h9b05688c, 32'h1f83d9ab, 32'h5be0cd19};

    // ---- xbuf read path: the filter reads while hashing, the link after
    reg  [K-1:0]  my_raddr;
    assign s_raddr = l_avail ? l_raddr : my_raddr;
    assign l_rdata = s_rdata;

    // ---- SHA-256 core
    reg          sha_go;
    reg  [255:0] sha_h;
    reg  [511:0] blk;
    wire         sha_done;
    wire [255:0] sha_out;
    zeq_sha256 u_sha (
        .clk(clk), .rst(rst), .start(sha_go), .h_in(sha_h), .block(blk),
        .done(sha_done), .h_out(sha_out));

    // ---- byte generator state
    localparam [3:0] F_IDLE = 0, F_BYTE = 1, F_FETCH0 = 2, F_FETCH1 = 3,
                     F_FETCH2 = 4, F_HASH = 5, F_OUTER = 6, F_OUTERW = 7,
                     F_DECIDE = 8, F_PASS = 9;
    reg [3:0]    fs;
    reg [15:0]   j;           // message byte index (0 .. P-1)
    reg [5:0]    pos;         // byte position within the block
    reg [K:0]    k;           // next index to fetch
    reg [IW+7:0] acc;         // bit accumulator for the packed solution
    reg [4:0]    nbits;
    reg [255:0]  h1;

    // header byte j
    wire [7:0] hdr_byte = hdr[8 * j[7:0] +: 8];
    // CompactSize prefix byte (j - 140)
    reg  [7:0] pfx_byte;
    always @* begin
        if (PFX == 1) pfx_byte = S16[7:0];
        else case (j - 16'd140)
            16'd0:   pfx_byte = 8'hFD;
            16'd1:   pfx_byte = S16[7:0];
            default: pfx_byte = S16[15:8];
        endcase
    end
    // padding / length bytes (j >= L)
    wire [15:0] lo = j - (P16 - 16'd8);                // length byte index
    wire [7:0]  pad_byte = (j == L16) ? 8'h80 :
                           (j >= P16 - 16'd8) ? LBITS[63 - 8 * lo[2:0] -: 8] : 8'h00;
    wire        in_sol   = (j >= SOL0) && (j < L16);
    wire [7:0]  sol_byte = acc[nbits - 1 -: 8];

    wire [255:0] h_rev;   // digest bytes reversed = little-endian number
    genvar gb;
    generate
        for (gb = 0; gb < 32; gb = gb + 1) begin : g_rev
            assign h_rev[255 - 8*gb -: 8] = sha_out[8*gb +: 8];
        end
    endgenerate

    always @(posedge clk) begin
        sha_go <= 1'b0;
        s_ack  <= 1'b0;
        if (rst || cancel) begin
            fs      <= F_IDLE;
            l_avail <= 1'b0;
            if (rst) dropped <= 0;
        end else case (fs)
        F_IDLE: if (s_avail && !s_ack) begin
            j     <= 0;
            pos   <= 0;
            k     <= 0;
            acc   <= 0;
            nbits <= 0;
            sha_h <= IV;
            fs    <= F_BYTE;
        end
        // produce one message byte into the block (fetching indices as
        // the bit accumulator runs low)
        F_BYTE: begin
            if (in_sol && nbits < 8) begin
                my_raddr <= k[K-1:0];
                fs       <= F_FETCH0;
            end else begin
                if (j < 16'd140)   blk[511 - 8*pos -: 8] <= hdr_byte;
                else if (j < SOL0) blk[511 - 8*pos -: 8] <= pfx_byte;
                else if (in_sol) begin
                    blk[511 - 8*pos -: 8] <= sol_byte;
                    nbits <= nbits - 5'd8;
                end else blk[511 - 8*pos -: 8] <= pad_byte;
                j   <= j + 1'b1;
                pos <= pos + 1'b1;
                if (pos == 6'd63) begin sha_go <= 1'b1; fs <= F_HASH; end
            end
        end
        F_FETCH0: fs <= F_FETCH1;     // address reaches xbuf
        F_FETCH1: fs <= F_FETCH2;     // registered read
        F_FETCH2: begin
            acc   <= (acc << IW) | {{8{1'b0}}, s_rdata[IW-1:0]};
            nbits <= nbits + IW[4:0];
            k     <= k + 1'b1;
            fs    <= F_BYTE;
        end
        F_HASH: if (sha_done) begin
            sha_h <= sha_out;
            if (j == P16) begin h1 <= sha_out; fs <= F_OUTER; end
            else fs <= F_BYTE;
        end
        // second SHA-256 over the 32-byte digest: one padded block
        F_OUTER: begin
            blk    <= {h1, 8'h80, 184'd0, 64'd256};
            sha_h  <= IV;
            sha_go <= 1'b1;
            fs     <= F_OUTERW;
        end
        F_OUTERW: if (sha_done) fs <= F_DECIDE;
        F_DECIDE: begin
            if (h_rev <= target_be) begin
                l_avail <= 1'b1;
                fs      <= F_PASS;
            end else begin
                s_ack   <= 1'b1;      // drop: release the solver
                dropped <= dropped + 1'b1;
                fs      <= F_IDLE;
            end
        end
        default: if (l_ack) begin     // F_PASS: link is sending it
            l_avail <= 1'b0;
            s_ack   <= 1'b1;
            fs      <= F_IDLE;
        end
        endcase
    end
endmodule

`default_nettype wire
