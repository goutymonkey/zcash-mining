// Scan-chain shift test on the scan-inserted Blake2b netlist (liberty cell
// functions, build/scan/scan_sim.v): with scan_en = 1 the NF flops form one
// shift register, so a random bit stream on scan_in reappears on scan_out
// exactly NF cycles later. Then a load / capture / unload round trip: shift
// a pattern in, pulse one functional clock (scan_en = 0), shift it out and
// check the captured state is not the loaded one (the D paths are live).
`timescale 1ns/1ps
module tb_scan;
    parameter integer N = 0, K = 0;   // unused (common -G flags)
    localparam integer NF = 2125;
    reg clk = 0, scan_en = 1, scan_in = 0;
    wire scan_out, done;
    wire [511:0] h_out;
    reg rst = 0, start = 0, last = 0;
    reg [511:0] h_in = 0;
    reg [1023:0] m = 0;
    reg [63:0] t = 0;

    zeq_blake2b_scan dut (.scan_en(scan_en), .scan_in(scan_in), .scan_out(scan_out),
        .clk(clk), .rst(rst), .start(start), .h_in(h_in), .m(m), .t(t),
        .last(last), .done(done), .h_out(h_out));

    reg [NF-1:0] pat, got;
    reg [31:0] lfsr = 32'hACE1_2345;
    integer i, errs = 0, diff = 0;

    task tick; begin #5 clk = 1; #5 clk = 0; end endtask
    function nextbit(input reg [31:0] s); nextbit = s[31] ^ s[21] ^ s[1] ^ s[0]; endfunction

    initial begin
        // 1. flush: NF cycles of random data, then NF more while checking
        for (i = 0; i < 3 * NF; i = i + 1) begin
            scan_in = lfsr[0];
            #1;
            // scan_out now holds the bit shifted in NF cycles ago
            if (i >= NF && scan_out !== pat[NF-1]) begin
                if (errs < 5) $display("shift mismatch at cycle %0d", i);
                errs = errs + 1;
            end
            pat = {pat[NF-2:0], lfsr[0]};
            lfsr = {lfsr[30:0], nextbit(lfsr)};
            #4 clk = 1; #5 clk = 0;
        end
        // 2. capture: load all-ones-and-zeros pattern, one functional clock
        //    with start = 1 (state updates), unload and count flips
        for (i = 0; i < NF; i = i + 1) begin
            scan_in = i[0]; tick;
        end
        scan_en = 0; start = 1; m = {16{64'h0123_4567_89ab_cdef}}; tick; start = 0; scan_en = 1;
        for (i = 0; i < NF; i = i + 1) begin
            #1 got = {got[NF-2:0], scan_out}; #4 clk = 1; #5 clk = 0;
        end
        for (i = 0; i < NF; i = i + 1)
            if (got[i] !== ((NF - 1 - i) % 2 == 1)) diff = diff + 1;
        $display("scan: %0d flops, %0d shift errors, capture changed %0d bits", NF, errs, diff);
        if (errs == 0 && diff > 0) $display("scan: PASS");
        else $display("scan: FAIL");
        $finish;
    end
endmodule
