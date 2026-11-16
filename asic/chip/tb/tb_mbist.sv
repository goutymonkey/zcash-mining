// zeq_mbist against a memory with injectable faults. A healthy memory must
// pass; every fault class March C- is meant to catch must fail.
module tb_mbist;
    parameter integer N = 48, K = 5;   // unused (common -G flags)
    localparam integer AW = 6, DW = 12, DEPTH = 1 << AW;
    reg clk = 0, rst = 1, start = 0;
    always #5 clk = ~clk;
    wire active, done, pass, we, re;
    wire [AW-1:0] waddr, raddr;
    wire [DW-1:0] wdata;
    wire fail_valid, fail_multirow;
    wire [AW-1:0] fail_addr;
    wire [DW-1:0] fail_expected, fail_observed;
    wire [2:0] fail_element;
    reg  [DW-1:0] rdata;
    reg  [DW-1:0] mem [0:DEPTH-1];
    integer fault;   // 0 none, 1 SA0, 2 SA1, 3 transition (0->1 fails), 4 addr alias, 5 coupling
    localparam integer FA = 13, FB = 3, FV = 40;   // victim word/bit, aggressor word

    zeq_mbist #(.AW(AW), .DW(DW)) dut (
        .clk(clk), .rst(rst), .start(start), .active(active), .done(done), .pass(pass),
        .we(we), .waddr(waddr), .wdata(wdata), .re(re), .raddr(raddr), .rdata(rdata),
        .fail_valid(fail_valid),.fail_addr(fail_addr),.fail_expected(fail_expected),
        .fail_observed(fail_observed),.fail_element(fail_element),.fail_multirow(fail_multirow));

    reg [DW-1:0] d;
    always @(posedge clk) begin
        if (we) begin
            d = wdata;
            if (fault == 3 && waddr == FA && wdata[FB] && !mem[FA][FB]) d[FB] = 1'b0;   // can't rise
            if (fault == 4 && waddr == FV) mem[FA] <= d;        // decoder: FV also writes FA
            else mem[waddr] <= d;
            if (fault == 5 && waddr == FV && wdata[0] != mem[FV][0]) mem[FA][FB] <= ~mem[FA][FB];
        end
        if (re) begin
            rdata <= mem[raddr];
            if (fault == 1 && raddr == FA) rdata[FB] <= 1'b0;
            if (fault == 2 && raddr == FA) rdata[FB] <= 1'b1;
        end
    end

    integer f, errors = 0;
    initial begin
        for (f = 0; f <= 5; f = f + 1) begin
            fault = f;
            rst = 1; repeat (3) @(posedge clk); rst = 0;
            @(posedge clk) start = 1;
            @(posedge clk) start = 0;
            wait (done);
            $display("fault class %0d: %s", f, pass ? "PASS" : "FAIL");
            if ((f == 0) != pass) errors = errors + 1;
            if ((f != 0) != fail_valid) $fatal(1,"missing/stale diagnostic");
            if(f!=0 && (fail_expected==fail_observed || fail_element==0 || fail_element>5))
                $fatal(1,"invalid first-failure comparison");
            if(f>=1 && f<=3 && (fail_addr!=FA || fail_multirow))
                $fatal(1,"single-row diagnostic incorrect");
        end
        if (errors) $fatal(1, "tb_mbist FAILED (%0d)", errors);
        $display("tb_mbist PASS: healthy memory passes, all 5 fault classes detected");
        $finish;
    end
endmodule
