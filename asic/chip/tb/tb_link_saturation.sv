// Transport-only stress: real UARTs, packet arbitration and receive FIFOs,
// with continuously available synthetic lane results. No solver/yield claim.
module tb_link_saturation;
    parameter integer SKEW = 0, DIV = 16, DURATION_NS = 500_000_000,
                      N = 48, K = 5, MAX_STALL_NS = K == 9 ? 50_000_000 : 5_000_000;
    localparam integer WORDS = 1 << K, LENGTH = 4 + 4*WORDS, RW = N/(K+1)+2;
    localparam real ROOT_HALF = SKEW == 0 ? 5.0 : 5.030;
    localparam real BIT_NS = DIV * 2.0 * ROOT_HALF;
    reg [3:0] clk = 0;
    always #(ROOT_HALF) clk[0] = ~clk[0];
    always #(SKEW == 0 ? 5.0 : 5.020) clk[1] = ~clk[1];
    always #(SKEW == 0 ? 5.0 : 5.010) clk[2] = ~clk[2];
    always #5.0 clk[3] = ~clk[3];
    reg rst = 1, ci = 1, finish_sources = 0;
    wire [4:0] cmd, rsp, busy;
    assign cmd[0] = ci;
    assign rsp[4] = 1;
    assign busy[4] = 1;
    integer received[0:3], emitted[0:3], high_water[0:3];
    time last_packet[0:3], max_gap[0:3];
    wire [3:0] idle;
    genvar g;
    generate for (g=0; g<4; g=g+1) begin : chip
        wire mid_start, lane_start, lane_ack, lane_abort;
        wire [K-1:0] raddr;
        reg mid_done = 0, available = 0, started = 0;
        reg [RW-1:0] sequence_id = 0;
        wire [RW-1:0] data = sequence_id ^ RW'(raddr);
        zeq_link #(.N(N), .K(K), .LANES(1), .DIV(DIV)) dut (
            .clk(clk[g]), .rst(rst), .addr_strap(g[1:0]),
            .ci(cmd[g]), .co(cmd[g+1]), .ri(rsp[g+1]), .ro(rsp[g]),
            .bi(busy[g+1]), .bo(busy[g]), .tsense(8'd30), .temp_pull(),
            .hdr_eff(), .mid_start(mid_start), .mid_done(mid_done),
            .lane_start(lane_start), .lane_abort(lane_abort), .lane_done(1'b0),
            .lane_nsol(8'd0), .lane_avail(available), .lane_ack(lane_ack),
            .sol_raddr(raddr), .lane_rdata(data), .target_be(),
            .bist_start(), .bist_done(1'b0), .bist_fail(1'b0));
        assign idle[g] = !available && dut.f_level == 0 && dut.ast == 0 && dut.tx_ready;
        always @(posedge clk[g]) begin
            mid_done <= mid_start;
            if (rst) begin
                available <= 0; started <= 0; sequence_id <= 0;
                emitted[g] = 0; high_water[g] = 0;
            end else begin
                if (started && !finish_sources && $time-last_packet[g]>time'(MAX_STALL_NS))
                    $fatal(1,"starvation bound exceeded source=%0d packets=%0d gap_ns=%0d",g,received[g],$time-last_packet[g]);
                if (int'(dut.f_level) > high_water[g]) high_water[g] = int'(dut.f_level);
                if (lane_start) started <= 1;
                if (lane_ack) begin
                    available <= 0;
                    sequence_id <= sequence_id + 1'b1;
                    emitted[g] += 1;
                end else if (started && !finish_sources) available <= 1;
                if (lane_abort) begin available <= 0; started <= 0; end
            end
        end
    end endgenerate

    function automatic [7:0] crc8(input [7:0] old, b);
        reg [7:0] c;
        begin
            c = old ^ b;
            for (integer j=0; j<8; j+=1) c = c[7] ? (c<<1)^8'h07 : c<<1;
            crc8 = c;
        end
    endfunction
    task automatic send_byte(input [7:0] b);
        begin
            ci=0; #(BIT_NS);
            for (integer j=0; j<8; j+=1) begin ci=b[j]; #(BIT_NS); end
            ci=1; #(BIT_NS);
        end
    endtask
    task automatic job();
        reg [7:0] crc, b;
        begin
            crc=0; send_byte(8'ha5);
            for(integer j=0;j<145;j+=1) begin
                case(j)
                    0:b=8'h01; 1:b=8'hff; 2:b=8'd141; 3:b=0; 4:b=8'd7;
                    default:b=0;
                endcase
                send_byte(b); crc=crc8(crc,b);
            end
            send_byte(crc);
        end
    endtask

    integer pos=0, address=0;
    reg [7:0] rb, crc=0;
    reg [31:0] word_value=0;
    initial begin
        for(integer j=0;j<4;j+=1) begin received[j]=0;last_packet[j]=0;max_gap[j]=0;end
        forever begin
            @(negedge rsp[0]); #(BIT_NS*1.5);
            for(integer j=0;j<8;j+=1) begin rb[j]=rsp[0]; #(BIT_NS); end
            if (rsp[0] !== 1'b1) $fatal(1,"bad serial stop bit");
            if(pos==0) begin
                if(rb!=8'h5a)$fatal(1,"bad packet start");
                crc=0;
            end else if(pos==1 && rb!=8'h81) $fatal(1,"unexpected response type");
            else if(pos==2) begin
                if(rb>3)$fatal(1,"unknown source address");
                address=int'(rb);
            end else if(pos==3 && rb!=8'(LENGTH)) $fatal(1,"wrong length");
            else if(pos==4 && rb!=8'(LENGTH>>8)) $fatal(1,"wrong length high");
            else if(pos==5 && rb!=7) $fatal(1,"wrong job");
            else if(pos>=6 && pos<=8 && rb!=0) $fatal(1,"wrong attempt");
            if(pos>=9 && pos<LENGTH+5) begin
                word_value={word_value[23:0],rb};
                if((pos-9)%4==3 && word_value != ((received[address]&((1<<RW)-1))^((pos-9)/4)))
                    $fatal(1,"payload loss/reorder source %0d packet %0d word %0d got %h",
                        address,received[address],(pos-9)/4,word_value);
            end
            if(pos==LENGTH+5) begin
                if(rb!=crc)$fatal(1,"packet CRC mismatch");
                if($time-last_packet[address]>max_gap[address])max_gap[address]=$time-last_packet[address];
                last_packet[address]=$time;
                received[address]+=1;
                pos=0;
            end else begin
                if(pos>0)crc=crc8(crc,rb);
                pos+=1;
            end
        end
    end

    task automatic summary();
        for(integer j=0;j<4;j+=1)
            $display("source=%0d received=%0d emitted=%0d high_water=%0d max_gap_ns=%0d",
                j,received[j],emitted[j],high_water[j],max_gap[j]);
    endtask
    initial begin
        #1000; rst=0; #1000; job();
        #(DURATION_NS);
        summary();
        finish_sources=1;
        // Each lane may retain one result. Drain it and all forwarding stages.
        for(integer j=0;j<20000 && idle!=4'b1111;j+=1) #(BIT_NS*10);
        if(idle!=4'b1111)$fatal(1,"transport did not drain");
        #(BIT_NS*12);
        for(integer j=0;j<4;j+=1) begin
            if(received[j]==0 || received[j]!=emitted[j])$fatal(1,"missing source packets");
        end
        if(pos!=0)$fatal(1,"partial packet at drain");
        summary();
        $display("link saturation PASS"); $finish;
    end
    initial begin
        #(DURATION_NS+100_000_000); summary(); $fatal(1,"transport watchdog expired");
    end
endmodule
