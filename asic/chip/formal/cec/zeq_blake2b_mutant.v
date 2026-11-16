// MUTANT for ./run.sh lec: h_out bit 0 inverted at finalization; must NOT be equivalent
// Blake2b compression function (RFC 7693), iterative.
//
// Four G functions run in parallel on the column step, then on the
// diagonal step. SPLIT sets how much of G one clock cycle does:
//   SPLIT = 1  all of G per cycle     24 cycles per compression (fast nodes)
//   SPLIT = 2  half of G per cycle    48 cycles
//   SPLIT = 4  a quarter per cycle    96 cycles: each cycle is one 64-bit
//              add plus xor/rotate (what a 130 nm process needs)
// plus one cycle to fold the result. h/m/t are little-endian 64-bit words packed with
// word 0 in the low bits, which makes byte i of a message sit at [8i+:8].
`default_nettype none

module zeq_blake2b #(
    parameter integer SPLIT = 1   // 1, 2 or 4
) (
    input  wire          clk,
    input  wire          rst,
    input  wire          start,
    input  wire [511:0]  h_in,
    input  wire [1023:0] m,
    input  wire [63:0]   t,     // byte counter (messages here are < 2^64)
    input  wire          last,  // final block flag
    output reg           done,  // one-cycle pulse, h_out valid from then on
    output reg  [511:0]  h_out
);
    localparam [511:0] IV = {
        64'h5be0cd19137e2179, 64'h1f83d9abfb41bd6b,
        64'h9b05688c2b3e6c1f, 64'h510e527fade682d1,
        64'ha54ff53a5f1d36f1, 64'h3c6ef372fe94f82b,
        64'hbb67ae8584caa73b, 64'h6a09e667f3bcc908
    };

    // message schedule: nibble i of row r is sigma[r][i]
    function [63:0] sigma_row(input [3:0] rnd);
        case (rnd)
            4'd0: sigma_row = 64'hfedcba9876543210;
            4'd1: sigma_row = 64'h357b20c16df984ae;
            4'd2: sigma_row = 64'h491763eadf250c8b;
            4'd3: sigma_row = 64'h8f04a562ebcd1397;
            4'd4: sigma_row = 64'hd386cb1efa427509;
            4'd5: sigma_row = 64'h91ef57d438b0a6c2;
            4'd6: sigma_row = 64'hb8293670a4def15c;
            4'd7: sigma_row = 64'ha2684f05931ce7bd;
            4'd8: sigma_row = 64'h5a417d2c803b9ef6;
            default: sigma_row = 64'h0dc3e9bf5167482a;
        endcase
    endfunction

    function [63:0] ror(input [63:0] x, input integer n);
        ror = (x >> n) | (x << (64 - n));
    endfunction

    // G is four quarter steps; ph selects which ones run this cycle.
    //   q0: a += b + x; d = ror(d ^ a, 32)    q1: c += d; b = ror(b ^ c, 24)
    //   q2: a += b + y; d = ror(d ^ a, 16)    q3: c += d; b = ror(b ^ c, 63)
    // The a/d half and the c/b half each use one shared adder whose
    // operand and rotation are chosen by ph. Returns {d, c, b, a}.
    function [127:0] q_ad(input [63:0] a, input [63:0] b, input [63:0] d,
                          input [63:0] mword, input second);
        reg [63:0] ta, dx;
        begin
            ta   = a + b + mword;
            dx   = d ^ ta;
            q_ad = {second ? ror(dx, 16) : ror(dx, 32), ta};
        end
    endfunction
    function [127:0] q_cb(input [63:0] c, input [63:0] d, input [63:0] b,
                          input second);
        reg [63:0] tc, bx;
        begin
            tc   = c + d;
            bx   = b ^ tc;
            q_cb = {second ? ror(bx, 63) : ror(bx, 24), tc};
        end
    endfunction
    function [255:0] gmix(input [63:0] a, input [63:0] b, input [63:0] c,
                       input [63:0] d, input [63:0] x, input [63:0] y,
                       input [1:0] ph);
        reg [63:0] ta, tb, tc, td;
        begin
            ta = a; tb = b; tc = c; td = d;
            if (SPLIT == 1) begin
                {td, ta} = q_ad(ta, tb, td, x, 1'b0);
                {tb, tc} = q_cb(tc, td, tb, 1'b0);
                {td, ta} = q_ad(ta, tb, td, y, 1'b1);
                {tb, tc} = q_cb(tc, td, tb, 1'b1);
            end else if (SPLIT == 2) begin
                {td, ta} = q_ad(ta, tb, td, ph[0] ? y : x, ph[0]);
                {tb, tc} = q_cb(tc, td, tb, ph[0]);
            end else if (!ph[0]) begin
                {td, ta} = q_ad(ta, tb, td, ph[1] ? y : x, ph[1]);
            end else begin
                {tb, tc} = q_cb(tc, td, tb, ph[1]);
            end
            gmix = {td, tc, tb, ta};
        end
    endfunction
    localparam integer PH_LAST_I = SPLIT - 1;
    localparam [1:0]   PH_LAST   = PH_LAST_I[1:0];

    reg [63:0]  v [0:15];
    reg [511:0] h_lat;  // chaining value, latched so callers may change h_in
    reg [3:0]   round;  // 0..11
    reg [1:0]   ph;     // quarter-step phase within G (SPLIT > 1)
    reg [3:0]   srow;   // round mod 10
    reg         step;   // 0 = column, 1 = diagonal
    reg         busy;
    reg         fold;

    wire [63:0] sig = sigma_row(srow);

    function [63:0] mw(input [3:0] slot);
        mw = m[64 * sig[4 * slot +: 4] +: 64];
    endfunction

    // lane assignment for the four parallel G units
    wire [3:0] a0 = 4'd0, a1 = 4'd1, a2 = 4'd2, a3 = 4'd3;
    wire [3:0] b0 = step ? 4'd5  : 4'd4;
    wire [3:0] b1 = step ? 4'd6  : 4'd5;
    wire [3:0] b2 = step ? 4'd7  : 4'd6;
    wire [3:0] b3 = step ? 4'd4  : 4'd7;
    wire [3:0] c0 = step ? 4'd10 : 4'd8;
    wire [3:0] c1 = step ? 4'd11 : 4'd9;
    wire [3:0] c2 = step ? 4'd8  : 4'd10;
    wire [3:0] c3 = step ? 4'd9  : 4'd11;
    wire [3:0] d0 = step ? 4'd15 : 4'd12;
    wire [3:0] d1 = step ? 4'd12 : 4'd13;
    wire [3:0] d2 = step ? 4'd13 : 4'd14;
    wire [3:0] d3 = step ? 4'd14 : 4'd15;
    wire [3:0] base = step ? 4'd8 : 4'd0;

    wire [255:0] g0 = gmix(v[a0], v[b0], v[c0], v[d0], mw(base + 4'd0), mw(base + 4'd1), ph);
    wire [255:0] g1 = gmix(v[a1], v[b1], v[c1], v[d1], mw(base + 4'd2), mw(base + 4'd3), ph);
    wire [255:0] g2 = gmix(v[a2], v[b2], v[c2], v[d2], mw(base + 4'd4), mw(base + 4'd5), ph);
    wire [255:0] g3 = gmix(v[a3], v[b3], v[c3], v[d3], mw(base + 4'd6), mw(base + 4'd7), ph);

    integer i;
    always @(posedge clk) begin
        done <= 1'b0;
        if (rst) begin
            busy <= 1'b0;
            fold <= 1'b0;
        end else if (start) begin
            h_lat <= h_in;
            for (i = 0; i < 8; i = i + 1) begin
                v[i]     <= h_in[64 * i +: 64];
                v[i + 8] <= IV[64 * i +: 64];
            end
            v[12] <= IV[64 * 4 +: 64] ^ t;
            v[14] <= last ? ~IV[64 * 6 +: 64] : IV[64 * 6 +: 64];
            round <= 4'd0;
            srow  <= 4'd0;
            step  <= 1'b0;
            ph    <= 2'd0;
            busy  <= 1'b1;
        end else if (busy) begin
            {v[d0], v[c0], v[b0], v[a0]} <= g0;
            {v[d1], v[c1], v[b1], v[a1]} <= g1;
            {v[d2], v[c2], v[b2], v[a2]} <= g2;
            {v[d3], v[c3], v[b3], v[a3]} <= g3;
            ph <= (ph == PH_LAST) ? 2'd0 : ph + 2'd1;
            if (ph == PH_LAST) step <= ~step;
            if (ph == PH_LAST && step) begin
                srow <= (srow == 4'd9) ? 4'd0 : srow + 4'd1;
                if (round == 4'd11) begin
                    busy <= 1'b0;
                    fold <= 1'b1;
                end
                round <= round + 4'd1;
            end
        end else if (fold) begin
            for (i = 0; i < 8; i = i + 1)
                h_out[64 * i +: 64] <= h_lat[64 * i +: 64] ^ v[i] ^ v[i + 8] ^ ((i == 0) ? 64'd1 : 64'd0);
            fold <= 1'b0;
            done <= 1'b1;
        end
    end
endmodule

`default_nettype wire
