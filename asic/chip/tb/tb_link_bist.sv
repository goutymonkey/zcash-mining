// UART-level test of destructive BIST versus job scheduling. The memory
// completion model deliberately holds a stale DONE high before acknowledging
// a new test, then lets the bench choose success/failure/completion timing.
module tb_link_bist;
    parameter integer HAS_BIST=1;
    parameter integer BOOT_BIST=0,N=48,K=5;
    localparam integer RW=N/(K+1)+2;
    localparam integer DIV=8;
    reg clk=0,rst=1,ci=1;
    always #5 clk=~clk;
    wire co,ro,bo,temp_pull,mid_start,lane_abort,bist_start;
    wire [1119:0] hdr_eff;
    wire [0:0] lane_start,lane_ack;
    wire [K-1:0] sol_raddr;
    wire [255:0] target_be;
    reg mid_done=0,bist_done=1,bist_fail=0;
    reg finish_test=0,finish_fail=0,model_busy=0;
    integer launch_delay=0,starts=0,midstarts=0,tests=0;
    zeq_link #(.N(N),.K(K),.DIV(DIV)
`ifndef LEGACY_LINK
        ,.HAS_BIST(HAS_BIST),.BOOT_BIST(BOOT_BIST)
`endif
    ) dut (
        .clk(clk),.rst(rst),.addr_strap(2'b00),.ci(ci),.co(co),
        .ri(1'b1),.ro(ro),.bi(1'b1),.bo(bo),.tsense(8'd30),.temp_pull(temp_pull),
        .hdr_eff(hdr_eff),.mid_start(mid_start),.mid_done(mid_done),
        .lane_start(lane_start),.lane_abort(lane_abort),.lane_done(1'b0),
        .lane_nsol(8'd0),.lane_avail(1'b0),.lane_ack(lane_ack),
        .sol_raddr(sol_raddr),.lane_rdata({RW{1'b0}}),.target_be(target_be),
        .bist_start(bist_start),.bist_done(bist_done),.bist_fail(bist_fail));

    always @(posedge clk) begin
        mid_done<=mid_start;
        if(rst) begin
            model_busy<=0;bist_done<=1;bist_fail<=0;launch_delay<=0;
        end else begin
            if(bist_start) begin
                if(model_busy) $fatal(1,"BIST restarted while active");
                tests+=1;model_busy<=1;launch_delay<=BOOT_BIST!=0?20000:8;
            end else if(launch_delay>0) begin
                launch_delay<=launch_delay-1;
                if(launch_delay==1) begin bist_done<=0;bist_fail<=0;end
            end else if(finish_test && model_busy) begin
                model_busy<=0;bist_done<=1;bist_fail<=finish_fail;
            end
            if(model_busy && (mid_start || |lane_start))
                $fatal(1,"mining started while memory BIST active");
            if(mid_start)midstarts+=1;
            if(|lane_start)starts+=1;
        end
    end
    function automatic [7:0] crc8(input [7:0] c,b);
        reg [7:0] v;
        begin
            v=c^b;
            for(integer j=0;j<8;j+=1)v=v[7]?((v<<1)^8'h07):(v<<1);
            crc8=v;
        end
    endfunction
    integer pongs=0,rx_pos=0;
    reg [7:0] pong_status=0,rx_byte,rx_crc=0;
    initial forever begin
        @(negedge ro); #(DIV*15);
        for(integer j=0;j<8;j+=1)begin rx_byte[j]=ro;#(DIV*10);end
        case(rx_pos)
            0: begin if(rx_byte!=8'h5a)$fatal(1,"bad PONG framing");rx_crc=0;end
            1: if(rx_byte!=8'h84)$fatal(1,"unexpected response type");
            2: if(rx_byte!=0)$fatal(1,"unexpected response address");
            3: if(rx_byte!=4)$fatal(1,"unexpected response length");
            4: if(rx_byte!=0)$fatal(1,"unexpected response length high byte");
            6: pong_status=rx_byte;
            9: begin
                if(rx_byte!=rx_crc)$fatal(1,"PONG CRC mismatch");
                pongs+=1;
            end
            default: ;
        endcase
        if(rx_pos>0 && rx_pos<9)rx_crc=crc8(rx_crc,rx_byte);
        rx_pos=rx_pos==9?0:rx_pos+1;
    end
    task automatic byte_out(input [7:0] b);
        begin
            ci=0;repeat(DIV)@(negedge clk);
            for(integer j=0;j<8;j+=1)begin ci=b[j];repeat(DIV)@(negedge clk);end
            ci=1;repeat(DIV)@(negedge clk);
        end
    endtask
    task automatic ping_expect(input [7:0] status);
        integer next_pong;
        begin
            next_pong=pongs+1;command(8'h04,0,0,0);
            wait(pongs==next_pong);
            if(pong_status!=status)$fatal(1,"PONG status got %h expected %h",pong_status,status);
            @(negedge clk);
        end
    endtask
    task automatic command(input [7:0] typ,id,input integer len,input bit bad_crc);
        reg [7:0] c;
        begin
            c=0;byte_out(8'ha5);
            byte_out(typ);c=crc8(c,typ);
            byte_out(0);c=crc8(c,0);
            byte_out(8'(len));c=crc8(c,8'(len));
            byte_out(8'(len>>8));c=crc8(c,8'(len>>8));
            for(integer j=0;j<len;j+=1)begin byte_out(id);c=crc8(c,id);end
            byte_out(c^(bad_crc?8'h01:8'h00));
            repeat(12)@(negedge clk);
        end
    endtask
    task automatic complete(input bit fail);
        begin
            if(!model_busy || bist_done)$fatal(1,"test did not acknowledge start");
            finish_fail=fail;finish_test=1;
            repeat(2)@(negedge clk);finish_test=0;
            repeat(20)@(negedge clk);
        end
    endtask
    integer saved_starts,saved_tests;
    task automatic restart;
        begin
            rst=1;repeat(8)@(negedge clk);rst=0;repeat(12)@(negedge clk);
            if(!model_busy || bo)$fatal(1,"startup BIST did not acquire ownership after reset");
        end
    endtask
    task automatic boot_complete(input bit fail);
        begin
            wait(!bist_done);repeat(4)@(negedge clk);complete(fail);
        end
    endtask
    task automatic boot_sequence;
        begin
            if(tests!=1 || !model_busy)$fatal(1,"startup BIST did not acquire ownership");
            if(bo)$fatal(1,"startup stale DONE or early JOB bypassed memory qualification");
            command(8'h01,8'ha1,141,0);
            if(!bist_done || starts!=0 || midstarts!=0 || !dut.bist_running)
                $fatal(1,"startup stale DONE or early JOB bypassed memory qualification");
            ping_expect(8'h02);
            command(8'h01,8'ha2,141,0);
            boot_complete(0);
            if(starts!=1 || hdr_eff[7:0]!=8'ha2)$fatal(1,"startup PASS did not dispatch latest queued JOB");
            command(8'h02,0,0,0);
            saved_starts=starts;
            restart();command(8'h01,8'hb1,141,0);command(8'h02,0,0,0);boot_complete(0);
            if(starts!=saved_starts || !bo)$fatal(1,"startup STOP did not discard queued work");

            restart();command(8'h01,8'hc1,141,0);boot_complete(1);
            if(starts!=saved_starts || bo)$fatal(1,"startup failure did not quarantine mining");
            ping_expect(8'h0e);command(8'h01,8'hc2,141,0);
            if(starts!=saved_starts)$fatal(1,"startup failed memory accepted JOB");
            command(8'h06,0,0,0);command(8'h01,8'hc3,141,0);boot_complete(0);
            if(starts!=saved_starts+1 || hdr_eff[7:0]!=8'hc3)$fatal(1,"startup retest did not recover");
            command(8'h02,0,0,0);saved_starts=starts;

            restart();command(8'h01,8'hd1,141,0);
            restart();
            if(starts!=saved_starts || !bist_done)$fatal(1,"reset bypassed fresh startup qualification");
            boot_complete(0);
            if(starts!=saved_starts || !bo)$fatal(1,"reset retained pre-reset queued startup JOB");
            command(8'h01,8'hd2,141,0);
            if(starts!=saved_starts+1 || tests!=6)$fatal(1,"startup reset recovery failed");
            $display("startup BIST PASS: stale DONE, latest JOB, STOP, failure quarantine, retest, reset requalification");
        end
    endtask
    initial begin
        repeat(8)@(negedge clk);rst=0;repeat(8)@(negedge clk);
        if(BOOT_BIST!=0 && HAS_BIST!=0)begin boot_sequence();$finish;end
        if(HAS_BIST==0)begin
            command(8'h06,0,0,0);
            if(tests!=0 || !bo)$fatal(1,"unsupported BIST blocked the link");
            ping_expect(8'h00);
            command(8'h01,8'hee,141,0);
            if(starts!=1)$fatal(1,"unsupported BIST blocked job dispatch");
            command(8'h02,0,0,0);ping_expect(8'h00);
            $display("link BIST interlock PASS: unsupported test ignored, no false result, mining operational");
            $finish;
        end
        command(8'h06,0,0,0);
        command(8'h01,8'ha1,141,0); // Must wait for BIST, despite stale prior DONE.
        if(bo || starts!=0 || midstarts!=0)$fatal(1,"BIST ownership not held");
        ping_expect(8'h02); // Busy, with the stale previous result hidden.
        command(8'h06,0,0,0);
        if(tests!=1)$fatal(1,"active BIST accepted another start");
        command(8'h01,8'ha2,141,0); // Latest queued header wins.
        complete(0);
        if(starts!=1 || hdr_eff[7:0]!=8'ha2)$fatal(1,"queued latest job not dispatched after PASS");
        saved_tests=tests;command(8'h06,0,0,0);
        if(tests!=saved_tests)$fatal(1,"BIST accepted while mining");
        command(8'h02,0,0,0);
        if(!bo)$fatal(1,"STOP failed to idle mining");
        ping_expect(8'h04);

        saved_starts=starts;
        command(8'h06,0,0,0);command(8'h01,8'hb1,141,0);
        command(8'h02,0,0,0); // STOP must cancel a pending job without aborting BIST.
        if(!model_busy || bo)$fatal(1,"STOP released BIST ownership");
        complete(0);
        if(starts!=saved_starts || !bo)$fatal(1,"STOP did not cancel queued BIST-time job");

        command(8'h06,0,0,0);command(8'h01,8'hc1,141,0);complete(1);
        if(starts!=saved_starts || bo)$fatal(1,"failed BIST allowed mining or advertised idle");
        ping_expect(8'h0e);
        command(8'h01,8'hc2,141,0);
        if(starts!=saved_starts)$fatal(1,"JOB after BIST failure was dispatched");
        command(8'h06,0,0,0);command(8'h01,8'hc3,141,0);complete(0);
        if(starts!=saved_starts+1 || hdr_eff[7:0]!=8'hc3)$fatal(1,"successful retest did not release queued work");
        command(8'h02,0,0,0);

        saved_tests=tests;command(8'h06,0,0,1);
        command(8'h06,0,1,0); // Malformed nonempty BIST must be ignored.
        if(tests!=saved_tests)$fatal(1,"malformed BIST accepted");
        command(8'h06,0,0,0);command(8'h01,8'hd1,141,0);
        rst=1;repeat(8)@(negedge clk);rst=0;repeat(30)@(negedge clk);
        if(model_busy || !bo || starts!=saved_starts+1)$fatal(1,"reset retained test or queued work");
        command(8'h01,8'hd2,141,0);
        if(starts!=saved_starts+2)$fatal(1,"reset recovery failed");
        $display("link BIST interlock PASS: UART job deferral, latest job, STOP, fail/retest, malformed command, reset");
        $finish;
    end
    initial begin #5_000_000; $fatal(1,"link BIST test timed out");end
endmodule
