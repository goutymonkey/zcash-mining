// Board-level test: four ZEQ-200s chained exactly like the ZEQ-HB4
// hashboard, each on its own oscillator, driven by a controller model.
//
//   host TX -> U0.CI, Uk.CO -> Uk+1.CI           (commands down)
//   Uk+1.RO -> Uk.RI, U0.RO -> host RX           (results up)
//   Uk+1.BO -> Uk.BI, U0.BO -> host BUSY         (busy chain)
//   host RSTN -> U0, Uk.RSTO -> Uk+1.RSTN        (reset chain)
//   top chip: RI = BI = 1 (tied to VDDIO); ADDR straps = k
//   TEMP pins wire-ORed with a pull-up (the board relays them with
//   isolators + diodes; electrically the same open-drain OR)
//
// Sequence: reset, PING (expect 4 PONGs), broadcast JOB 1, over-temp on
// chip 2 (TEMP must go low) then SET_OT on chip 2 only (TEMP released),
// wait for every chip to finish ATTEMPTS attempts of job 1, broadcast JOB 2
// (new header), wait for ATTEMPTS attempts of job 2, STOP, wait for BUSY.
// All upstream bytes go to chain_rx.hex for check_chain.py.
module tb_chain;
    parameter integer N = 48, K = 5, DIV = 8, CHIPS = 4, ATTEMPTS = 2, LANES = 2, HASH_SPLIT = 1, ARCH = 0,
                     PAR_BB = 4, PAR_PB = 2, PAR_SB = 8, PAR_HPB = PAR_PB, SHARE_FILTER = 1;
    localparam real BIT_NS = DIV * 10.0;

    // one oscillator per domain, a few hundred ppm apart
    reg [CHIPS-1:0] clk = 0;
    always #5.000 clk[0] = ~clk[0];
    always #5.013 clk[1] = ~clk[1];
    always #4.991 clk[2] = ~clk[2];
    always #5.022 clk[3] = ~clk[3];

    reg  host_tx = 1, host_rstn = 0;
    wire [CHIPS:0] cmd;    // cmd[k] feeds chip k's CI
    wire [CHIPS:0] rsp;    // rsp[k] is chip k's RO; rsp[CHIPS] = idle high
    wire [CHIPS:0] busy;   // busy[k] is chip k's BO
    wire [CHIPS:0] rstn;
    tri1 ot_n;             // TEMP wire-OR with pull-up

    assign cmd[0]      = host_tx;
    assign rstn[0]     = host_rstn;
    assign rsp[CHIPS]  = 1'b1;
    assign busy[CHIPS] = 1'b1;

    genvar k;
    generate
        for (k = 0; k < CHIPS; k = k + 1) begin : g_chip
`ifdef TEST_CARAVEL
            // Exercise the exact physical top and its GPIO wiring. The shuttle
            // has a fixed divider of 16 and receives temperature over LA.
            reg [7:0] temperature = 8'd60;
            wire [37:0] gpio_in, gpio_out, gpio_oeb;
            wire [127:0] la_out;
            wire [2:0] irq;
            wire wb_ack;
            wire [31:0] wb_data;
            wire [28:0] analog_unused;
            assign gpio_in = {20'd0, k[1:0], 1'b0, busy[k+1], 1'b0, rsp[k+1],
                              1'b0, cmd[k], 1'b0, rstn[k], 8'd0};
            assign rstn[k+1] = gpio_out[9];
            assign cmd[k+1] = gpio_out[11];
            assign rsp[k] = gpio_out[13];
            assign busy[k] = gpio_out[15];
            assign ot_n = gpio_oeb[18] ? 1'bz : gpio_out[18];
            user_project_wrapper u_chip (
                .wb_clk_i(clk[k]), .wb_rst_i(1'b0), .wbs_stb_i(1'b0),
                .wbs_cyc_i(1'b0), .wbs_we_i(1'b0), .wbs_sel_i(4'd0),
                .wbs_dat_i(32'd0), .wbs_adr_i(32'd0), .wbs_ack_o(wb_ack),
                .wbs_dat_o(wb_data), .user_clock2(clk[k]),
                .la_data_in({120'd0, temperature}), .la_data_out(la_out),
                .la_oenb({128{1'b1}}), .io_in(gpio_in), .io_out(gpio_out),
                .io_oeb(gpio_oeb), .analog_io(analog_unused), .user_irq(irq));
            always @(negedge clk[k]) if (host_rstn) begin
                if ((gpio_oeb | (38'd1 << 18)) !==
                    ~((38'd1 << 9) | (38'd1 << 11) | (38'd1 << 13) |
                      (38'd1 << 15) | (38'd1 << 19) | (38'd1 << 20)))
                    $fatal(1, "wrapper GPIO direction mismatch");
                if (gpio_out[20:18] !== 3'b000 || wb_ack !== 0 || wb_data !== 0)
                    $fatal(1, "wrapper reserved outputs or Wishbone response mismatch");
                if (irq !== {2'b00, ~gpio_oeb[18]} ||
                    la_out !== {120'd0, ~gpio_oeb[18], busy[k], rsp[k], cmd[k+1],
                                rstn[k+1], busy[k+1], rsp[k+1], cmd[k]})
                    $fatal(1, "wrapper interrupt or LA readback mismatch");
            end
`else
            wire clko_unused;
            zeq200 #(.N(N), .K(K), .LANES(LANES), .DIV(DIV), .HASH_SPLIT(HASH_SPLIT), .ARCH(ARCH), .SHARE_FILTER(SHARE_FILTER),
                     .PAR_BB(PAR_BB), .PAR_PB(PAR_PB), .PAR_SB(PAR_SB), .PAR_HPB(PAR_HPB)) u_chip (
                .CLKI(clk[k]), .CLKO(clko_unused),
                .CI(cmd[k]), .CO(cmd[k+1]),
                .RI(rsp[k+1]), .RO(rsp[k]),
                .BI(busy[k+1]), .BO(busy[k]),
                .RSTN(rstn[k]), .RSTO(rstn[k+1]),
                .ADDR0(k[0]), .ADDR1(k[1]),
                .TEMP(ot_n));
`endif
        end
    endgenerate

    // ---------------------------------------------------- host UART
    task automatic send_byte(input [7:0] b);
        integer i;
        begin
            host_tx = 0; #(BIT_NS);
            for (i = 0; i < 8; i = i + 1) begin host_tx = b[i]; #(BIT_NS); end
            host_tx = 1; #(BIT_NS);
        end
    endtask

    function automatic [7:0] crc8(input [7:0] c, input [7:0] b);
        reg [7:0] x;
        integer i;
        begin
            x = c ^ b;
            for (i = 0; i < 8; i = i + 1) x = x[7] ? ((x << 1) ^ 8'h07) : (x << 1);
            crc8 = x;
        end
    endfunction

    reg [7:0] jobs [0:279];   // two 140-byte headers
    // use_job = 0: every payload byte is b0; else payload is job id b0
    // followed by header number use_job (1 or 2)
    task automatic send_packet(input [7:0] typ, input [7:0] addr, input integer len,
                               input integer use_job, input [7:0] b0);
        reg [7:0] c, v;
        integer i;
        begin
            c = 0;
            send_byte(8'hA5);
            send_byte(typ);  c = crc8(c, typ);
            send_byte(addr); c = crc8(c, addr);
            send_byte(len[7:0]);  c = crc8(c, len[7:0]);
            send_byte(len[15:8]); c = crc8(c, len[15:8]);
            for (i = 0; i < len; i = i + 1) begin
                if (use_job == 0 || i == 0) v = b0;
                else v = jobs[(use_job - 1) * 140 + i - 1];
                send_byte(v); c = crc8(c, v);
            end
            send_byte(c);
        end
    endtask

    // SET_TARGET: 32-byte big-endian share target
    task automatic send_target(input [7:0] addr, input [255:0] tgt);
        reg [7:0] c, v;
        integer i;
        begin
            c = 0;
            send_byte(8'hA5);
            send_byte(8'h05); c = crc8(c, 8'h05);
            send_byte(addr);  c = crc8(c, addr);
            send_byte(8'd32); c = crc8(c, 8'd32);
            send_byte(8'd0);  c = crc8(c, 8'd0);
            for (i = 0; i < 32; i = i + 1) begin
                v = tgt[255 - 8*i -: 8];
                send_byte(v); c = crc8(c, v);
            end
            send_byte(c);
        end
    endtask

    // ------------------------------------- upstream capture + parsing
    integer fd, nbytes = 0, pongs = 0;
    integer dones [0:CHIPS-1];    // DONE packets of the current job
    reg [7:0] cur_job = 8'd1;
    reg [7:0] pjob;
    integer pidx = 0, plen = 0;
    reg [7:0] ptyp, paddr;
    reg [7:0] rb;
    integer i;
    integer cb;   // capture's own bit counter (i belongs to the host sequence)
    initial begin
        for (i = 0; i < CHIPS; i = i + 1) dones[i] = 0;
        fd = $fopen("chain_rx.hex", "w");
        forever begin
            @(negedge rsp[0]);
            #(BIT_NS * 1.5);
            for (cb = 0; cb < 8; cb = cb + 1) begin rb[cb] = rsp[0]; #(BIT_NS); end
            $fwrite(fd, "%02x\n", rb);
            nbytes = nbytes + 1;
            if (pidx == 1) ptyp = rb;
            if (pidx == 2) paddr = rb;
            if (pidx == 3) plen = {24'd0, rb};
            if (pidx == 4) plen = plen | {16'd0, rb, 8'd0};
            if (pidx == 5) pjob = rb;
            pidx = pidx + 1;
            if (pidx > 4 && pidx == plen + 6) begin
                if (ptyp == 8'h84) pongs = pongs + 1;
                if (ptyp == 8'h85 && paddr < 8'd4 && pjob == cur_job)
                    dones[paddr[1:0]] = dones[paddr[1:0]] + 1;
                pidx = 0;
            end
        end
    end

    function automatic integer min_done();
        integer m, c;
        begin
            m = dones[0];
            for (c = 1; c < CHIPS; c = c + 1) if (dones[c] < m) m = dones[c];
            min_done = m;
        end
    endfunction

    // per-hop monitors: every byte each chip sends upstream, for debugging
    genvar m;
    generate
        for (m = 1; m < CHIPS; m = m + 1) begin : g_mon
            integer mfd;
            reg [7:0] mb;
            integer bi_;
            initial begin
                mfd = $fopen($sformatf("hop%0d.hex", m), "w");
                forever begin
                    @(negedge rsp[m]);
                    #(BIT_NS * 1.5);
                    for (bi_ = 0; bi_ < 8; bi_ = bi_ + 1) begin mb[bi_] = rsp[m]; #(BIT_NS); end
                    $fwrite(mfd, "%02x %0t\n", mb, $time);
                    $fflush(mfd);
                end
            end
        end
    endgenerate

    // --------------------------------------------------------- host
    time t0;
    initial begin
        $readmemh("chain_job.hex", jobs);
        #(1000);
        host_rstn = 1;
        #(2000);

        send_packet(8'h04, 8'hFF, 0, 0, 8'h00);                 // PING all
        t0 = $time;
        while (pongs < CHIPS && $time - t0 < 5_000_000) #(BIT_NS * 10);
        if (pongs != CHIPS) $fatal(1, "expected %0d PONGs, got %0d", CHIPS, pongs);
        $display("[%0t] PING: %0d/%0d chips answered", $time, pongs, CHIPS);

        send_packet(8'h01, 8'hFF, 141, 1, 8'd1);                // JOB 1, all
        #(BIT_NS * 20);
        if (busy[0] !== 1'b0) $fatal(1, "BUSY did not assert after JOB");
        $display("[%0t] JOB broadcast, BUSY asserted", $time);

        // over-temperature on chip 2 only
`ifdef TEST_CARAVEL
        tb_chain.g_chip[2].temperature = 8'd220;
`else
        tb_chain.g_chip[2].u_chip.u_tsense.code_r = 8'd220;     // above default 200
`endif
        #(2000);
        if (ot_n !== 1'b0) $fatal(1, "TEMP not pulled low by hot chip 2");
        $display("[%0t] chip 2 hot: TEMP asserted", $time);
        send_packet(8'h03, 8'h02, 1, 0, 8'd240);                // SET_OT chip 2 -> 240
        #(2000);
        if (ot_n !== 1'b1) $fatal(1, "TEMP still low after raising chip 2 threshold");
        $display("[%0t] chip 2 threshold raised: TEMP released", $time);

        // poll: wait() on a function of the dones[] array is not
        // re-evaluated when the array changes
        t0 = $time;
        while (min_done() < ATTEMPTS && $time - t0 < 400_000_000) #(BIT_NS * 10);
        if (min_done() < ATTEMPTS) $fatal(1, "chips did not finish %0d attempts", ATTEMPTS);
        $display("[%0t] job 1: every chip finished >= %0d attempts", $time, ATTEMPTS);

        cur_job = 8'd2;
        for (i = 0; i < CHIPS; i = i + 1) dones[i] = 0;
        // job 2 runs with a share target that about half the solutions meet,
        // for 4 attempts per chip so both outcomes occur
        send_target(8'hFF, {1'b1, 255'd0});
        send_packet(8'h01, 8'hFF, 141, 2, 8'd2);                // JOB 2, all
        t0 = $time;
        while (min_done() < 2 * ATTEMPTS && $time - t0 < 800_000_000) #(BIT_NS * 10);
        if (min_done() < 2 * ATTEMPTS) $fatal(1, "job 2: chips did not finish %0d attempts", 2 * ATTEMPTS);
        $display("[%0t] job 2: every chip finished >= %0d attempts", $time, 2 * ATTEMPTS);

        send_packet(8'h02, 8'hFF, 0, 0, 8'h00);                 // STOP all
        t0 = $time;
        while (busy[0] !== 1'b1 && $time - t0 < 50_000_000) #(BIT_NS * 10);
        if (busy[0] !== 1'b1) $fatal(1, "BUSY still asserted after STOP");
        // Drain every hop's FIFO plus its own pending packet. Bypass mode
        // sends more traffic; the old 400-byte delay truncated the capture.
        #(BIT_NS * 10 * CHIPS * 8 * (4 * (1 << K) + 16));
        if (pidx != 0) $fatal(1, "incomplete upstream packet after drain");
        $fclose(fd);
        $display("tb_chain: %0d upstream bytes captured, job-2 DONE per chip: %0d %0d %0d %0d",
                 nbytes, dones[0], dones[1], dones[2], dones[3]);
        $finish;
    end
endmodule
