// zeq_share unit test: each vector offers one solution; the filter must
// forward it (and the link reads back the same indices) iff the Zcash
// block hash meets the target, else drop it. Expected values: hashlib.
module tb_share;
    parameter integer N = 48, K = 5, NV = 32;
    localparam integer CB = N / (K + 1), RW = CB + 2, NSOL = 1 << K;
    reg clk = 0, rst = 1;
    always #5 clk = ~clk;

    reg  [1119:0] hdr;
    reg  [255:0]  target;
    reg  [RW-1:0] xbuf [0:NSOL-1];
    reg  [RW-1:0] xq;
    reg           s_avail = 0, l_ack = 0;
    reg  [K-1:0]  l_raddr = 0;
    wire          s_ack, l_avail;
    wire [K-1:0]  s_raddr;
    wire [RW-1:0] l_rdata;
    wire [15:0]   dropped;
    always @(posedge clk) xq <= xbuf[s_raddr];   // solver xbuf: registered read

    zeq_share #(.N(N), .K(K)) dut (
        .clk(clk), .rst(rst), .cancel(1'b0), .hdr(hdr), .target_be(target),
        .s_avail(s_avail), .s_ack(s_ack), .s_raddr(s_raddr), .s_rdata(xq),
        .l_avail(l_avail), .l_ack(l_ack), .l_raddr(l_raddr), .l_rdata(l_rdata),
        .dropped(dropped));

    integer fd, v, i, want, got, errors = 0, passes = 0, cyc;
    reg [8*400-1:0] line;
    initial begin
        fd = $fopen("share_vec.txt", "r");
        repeat (3) @(posedge clk);
        rst <= 0;
        for (v = 0; v < NV; v = v + 1) begin
            if ($fscanf(fd, "%h %h %d", hdr, target, want) != 3) $fatal(1, "bad vector file");
            for (i = 0; i < NSOL; i = i + 1)
                if ($fscanf(fd, "%h", xbuf[i]) != 1) $fatal(1, "bad index");
            @(posedge clk) s_avail <= 1;
            cyc = 0;
            got = -1;
            while (got < 0) begin
                @(posedge clk); cyc = cyc + 1;
                if (l_avail) got = 1;
                if (s_ack) got = 0;
            end
            if (got == 1) begin
                // the link reads the solution through the filter
                for (i = 0; i < NSOL; i = i + 1) begin
                    l_raddr <= i[K-1:0];
                    @(posedge clk); @(posedge clk); #1;
                    if (l_rdata !== xbuf[i]) begin errors = errors + 1; end
                end
                @(posedge clk) l_ack <= 1;
                @(posedge clk) l_ack <= 0;
                while (!s_ack) @(posedge clk);
            end
            @(posedge clk) s_avail <= 0;
            @(posedge clk);
            if (got != want) begin
                errors = errors + 1;
                $display("vector %0d: filter %s, expected %s", v, (got != 0) ? "passed" : "dropped", (want != 0) ? "pass" : "drop");
            end
            passes = passes + got;
        end
        $display("tb_share: %0d vectors, %0d passed, %0d dropped (counter %0d), %0d errors, %0d cycles last",
                 NV, passes, NV - passes, dropped, errors, cyc);
        if (errors != 0) $fatal(1, "tb_share FAILED");
        $display("tb_share PASS");
        $finish;
    end
endmodule
