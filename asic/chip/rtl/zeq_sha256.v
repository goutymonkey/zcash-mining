// SHA-256 compression (FIPS 180-4), one round per cycle: 64 cycles per
// 512-bit block plus one to fold. Words are big-endian per the standard:
// block word 0 = block[511:480], state word 0 = state[255:224].
`default_nettype none

module zeq_sha256 (
    input  wire         clk,
    input  wire         rst,
    input  wire         start,
    input  wire [255:0] h_in,
    input  wire [511:0] block,
    output reg          done,
    output reg  [255:0] h_out
);
    function [31:0] kconst(input [5:0] i);
        case (i)
            6'd0:  kconst = 32'h428a2f98; 6'd1:  kconst = 32'h71374491;
            6'd2:  kconst = 32'hb5c0fbcf; 6'd3:  kconst = 32'he9b5dba5;
            6'd4:  kconst = 32'h3956c25b; 6'd5:  kconst = 32'h59f111f1;
            6'd6:  kconst = 32'h923f82a4; 6'd7:  kconst = 32'hab1c5ed5;
            6'd8:  kconst = 32'hd807aa98; 6'd9:  kconst = 32'h12835b01;
            6'd10: kconst = 32'h243185be; 6'd11: kconst = 32'h550c7dc3;
            6'd12: kconst = 32'h72be5d74; 6'd13: kconst = 32'h80deb1fe;
            6'd14: kconst = 32'h9bdc06a7; 6'd15: kconst = 32'hc19bf174;
            6'd16: kconst = 32'he49b69c1; 6'd17: kconst = 32'hefbe4786;
            6'd18: kconst = 32'h0fc19dc6; 6'd19: kconst = 32'h240ca1cc;
            6'd20: kconst = 32'h2de92c6f; 6'd21: kconst = 32'h4a7484aa;
            6'd22: kconst = 32'h5cb0a9dc; 6'd23: kconst = 32'h76f988da;
            6'd24: kconst = 32'h983e5152; 6'd25: kconst = 32'ha831c66d;
            6'd26: kconst = 32'hb00327c8; 6'd27: kconst = 32'hbf597fc7;
            6'd28: kconst = 32'hc6e00bf3; 6'd29: kconst = 32'hd5a79147;
            6'd30: kconst = 32'h06ca6351; 6'd31: kconst = 32'h14292967;
            6'd32: kconst = 32'h27b70a85; 6'd33: kconst = 32'h2e1b2138;
            6'd34: kconst = 32'h4d2c6dfc; 6'd35: kconst = 32'h53380d13;
            6'd36: kconst = 32'h650a7354; 6'd37: kconst = 32'h766a0abb;
            6'd38: kconst = 32'h81c2c92e; 6'd39: kconst = 32'h92722c85;
            6'd40: kconst = 32'ha2bfe8a1; 6'd41: kconst = 32'ha81a664b;
            6'd42: kconst = 32'hc24b8b70; 6'd43: kconst = 32'hc76c51a3;
            6'd44: kconst = 32'hd192e819; 6'd45: kconst = 32'hd6990624;
            6'd46: kconst = 32'hf40e3585; 6'd47: kconst = 32'h106aa070;
            6'd48: kconst = 32'h19a4c116; 6'd49: kconst = 32'h1e376c08;
            6'd50: kconst = 32'h2748774c; 6'd51: kconst = 32'h34b0bcb5;
            6'd52: kconst = 32'h391c0cb3; 6'd53: kconst = 32'h4ed8aa4a;
            6'd54: kconst = 32'h5b9cca4f; 6'd55: kconst = 32'h682e6ff3;
            6'd56: kconst = 32'h748f82ee; 6'd57: kconst = 32'h78a5636f;
            6'd58: kconst = 32'h84c87814; 6'd59: kconst = 32'h8cc70208;
            6'd60: kconst = 32'h90befffa; 6'd61: kconst = 32'ha4506ceb;
            6'd62: kconst = 32'hbef9a3f7; default: kconst = 32'hc67178f2;
        endcase
    endfunction

    function [31:0] rotr(input [31:0] x, input integer n);
        rotr = (x >> n) | (x << (32 - n));
    endfunction

    reg [31:0] w [0:15];     // message schedule window
    reg [31:0] a, b, c, d, e, f, g, h;
    reg [255:0] h_lat;
    reg [5:0]  t;
    reg        busy, fold;

    wire [31:0] s1  = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25);
    wire [31:0] ch  = (e & f) ^ (~e & g);
    wire [31:0] t1  = h + s1 + ch + kconst(t) + w[0];
    wire [31:0] s0  = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22);
    wire [31:0] maj = (a & b) ^ (a & c) ^ (b & c);
    wire [31:0] t2  = s0 + maj;
    // next schedule word (for round t+16)
    wire [31:0] ws0 = rotr(w[1], 7) ^ rotr(w[1], 18) ^ (w[1] >> 3);
    wire [31:0] ws1 = rotr(w[14], 17) ^ rotr(w[14], 19) ^ (w[14] >> 10);
    wire [31:0] wn  = w[0] + ws0 + w[9] + ws1;

    integer i;
    always @(posedge clk) begin
        done <= 1'b0;
        if (rst) begin
            busy <= 1'b0;
            fold <= 1'b0;
        end else if (start) begin
            for (i = 0; i < 16; i = i + 1) w[i] <= block[511 - 32*i -: 32];
            {a, b, c, d, e, f, g, h} <= h_in;
            h_lat <= h_in;
            t     <= 0;
            busy  <= 1'b1;
        end else if (busy) begin
            h <= g; g <= f; f <= e; e <= d + t1;
            d <= c; c <= b; b <= a; a <= t1 + t2;
            for (i = 0; i < 15; i = i + 1) w[i] <= w[i + 1];
            w[15] <= wn;
            t <= t + 1'b1;
            if (t == 6'd63) begin busy <= 1'b0; fold <= 1'b1; end
        end else if (fold) begin
            h_out <= {h_lat[255:224] + a, h_lat[223:192] + b, h_lat[191:160] + c,
                      h_lat[159:128] + d, h_lat[127:96]  + e, h_lat[95:64]   + f,
                      h_lat[63:32]   + g, h_lat[31:0]    + h};
            fold  <= 1'b0;
            done  <= 1'b1;
        end
    end
endmodule

`default_nettype wire
