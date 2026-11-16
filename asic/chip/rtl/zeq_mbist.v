// March C- memory BIST for a zeq_ram-style 1W1R memory.
//
// March C-:  {up(w0); up(r0,w1); up(r1,w0); down(r0,w1); down(r1,w0); up(r0)}
// covers stuck-at, transition, address-decoder and most coupling faults.
// Background data alternates per element (all-0 / all-1 words). While
// `active`, the BIST owns the memory ports (the wrapper muxes them);
// `pass` is valid when `done` rises and stays until the next start.
`default_nettype none

module zeq_mbist #(
    parameter integer AW = 8,
    parameter integer DW = 8,
    parameter integer DEPTH = 1 << AW
) (
    input  wire          clk,
    input  wire          rst,
    input  wire          start,
    output reg           active,
    output reg           done,
    output reg           pass,
    // memory port (to the mux in front of the RAM)
    output reg           we,
    output reg  [AW-1:0] waddr,
    output reg  [DW-1:0] wdata,
    output reg           re,
    output reg  [AW-1:0] raddr,
    input  wire [DW-1:0] rdata,
    // First failing comparison, sticky until reset or the next accepted test.
    output reg           fail_valid,
    output reg [AW-1:0]   fail_addr,
    output reg [DW-1:0]   fail_expected,
    output reg [DW-1:0]   fail_observed,
    output reg [2:0]      fail_element,
    output reg           fail_multirow
);
    localparam integer  LAST_I = DEPTH - 1;
    localparam [AW-1:0] LAST   = LAST_I[AW-1:0];
    // element: 0 w0 up, 1 r0w1 up, 2 r1w0 up, 3 r0w1 down, 4 r1w0 down, 5 r0 up
    reg [2:0]    el;
    reg [AW-1:0] a;
    reg [1:0]    ph;         // 0 read, 1 compare+write, 2 (element 5) compare
    reg [DW-1:0] exp_word;
    wire         down = (el == 3) || (el == 4);
    wire         rd_val = (el == 1 || el == 3 || el == 5) ? 1'b0 : 1'b1;   // expected
    wire         wr_val = (el == 1 || el == 3) ? 1'b1 : 1'b0;
    wire         at_end = down ? (a == 0) : (a == LAST);

    always @(posedge clk) begin
        we <= 1'b0;
        re <= 1'b0;
        if (rst) begin
            active <= 1'b0;
            done   <= 1'b0;
            pass   <= 1'b0;
            fail_valid <= 0; fail_addr <= 0; fail_expected <= 0;
            fail_observed <= 0; fail_element <= 0; fail_multirow <= 0;
        end else if (start && !active) begin
            active <= 1'b1;
            done   <= 1'b0;
            pass   <= 1'b1;
            fail_valid <= 0; fail_addr <= 0; fail_expected <= 0;
            fail_observed <= 0; fail_element <= 0; fail_multirow <= 0;
            el     <= 0;
            a      <= 0;
            ph     <= 0;
        end else if (active) begin
            if (el == 0) begin                       // up(w0)
                we <= 1'b1; waddr <= a; wdata <= {DW{1'b0}};
                if (a == LAST) begin el <= 1; a <= 0; ph <= 0; end
                else a <= a + 1'b1;
            end else if (ph == 0) begin             // read
                re <= 1'b1; raddr <= a;
                exp_word <= {DW{rd_val}};
                ph <= 1;
            end else if (ph == 1) begin             // read data issued, wait
                ph <= 2;
            end else begin                          // compare (+ write)
                if (rdata != exp_word) begin
                    pass <= 1'b0;
                    if (!fail_valid) begin
                        fail_valid <= 1'b1;
                        fail_addr <= a;
                        fail_expected <= exp_word;
                        fail_observed <= rdata;
                        fail_element <= el;
                    end else if (a != fail_addr) fail_multirow <= 1'b1;
                end
                if (el != 5) begin we <= 1'b1; waddr <= a; wdata <= {DW{wr_val}}; end
                ph <= 0;
                if (at_end) begin
                    if (el == 5) begin active <= 1'b0; done <= 1'b1; end
                    else begin
                        el <= el + 1'b1;
                        a  <= (el == 2 || el == 3) ? LAST : {AW{1'b0}};  // next element's start
                    end
                end else a <= down ? a - 1'b1 : a + 1'b1;
            end
        end
    end
endmodule

`default_nettype wire
