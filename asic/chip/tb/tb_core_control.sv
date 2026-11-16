module tb_core_control;
    parameter integer N=48,K=5,BB=4,PB=2,HPB=PB,HASH_SPLIT=1,SB=7,SLOTS=80,DIV=8,STAGED_NETWORK=0,PACKED_TABLES=1;
    parameter integer GMAX=16,GROUP_REPLAY=0;
    parameter integer BUCKET0_SLOTS=SLOTS;
    parameter integer DROP_ZERO=0,LEAF_SET=0,HASH_UNITS=1;
    localparam integer CB=N/(K+1), RW=CB+2;
    localparam real BIT_NS=DIV*10.0;
    reg clk=0,rst_n=0,ci=1,ri=1,bi=1;
    always #5 clk=~clk;
    wire co,ro,bo,rsto_n,temp_pull;
    wire core_reset,solver_busy,lane_avail,lane_ack,cmd_job,cmd_stop,sending_sol,bist_done,bist_fail;
    wire bist_running,mid_start,lane_start;
    wire [7:0] solver_round;
    wire [1:0] tx_state;
    wire [15:0] filter_drops;
    wire [1:0] link_state;
    wire [2:0] builder_state;
    wire [15:0] fifo_level;
    wire pending_done, link_room, link_run, tx_ready;
    generate if (N==200 && K==9) begin : g_production
        zeq200x #(.DROP_ZERO(DROP_ZERO),.LEAF_SET(LEAF_SET),.HASH_UNITS(HASH_UNITS),.GMAX(GMAX),.GROUP_REPLAY(GROUP_REPLAY),.PB(PB),.HPB(HPB),.HASH_SPLIT(HASH_SPLIT),.SLOTS(SLOTS),.BUCKET0_SLOTS(BUCKET0_SLOTS),.PACKED_TABLES(PACKED_TABLES),.STAGED_NETWORK(STAGED_NETWORK),.DIV(DIV)) dut (
            .clk(clk),.rst_n(rst_n),.rsto_n(rsto_n),.addr_strap(2'b00),.ci(ci),.co(co),
            .ri(ri),.ro(ro),.bi(bi),.bo(bo),.tsense(8'd60),.temp_pull(temp_pull));
        assign core_reset=dut.u_core.rst;
        assign link_state=dut.u_core.u_link.cst;
        assign builder_state=dut.u_core.u_link.bst;
        assign fifo_level=16'(dut.u_core.u_link.f_level);
        assign pending_done=dut.u_core.u_link.done_pend[0];
        assign link_room=dut.u_core.u_link.own_room;
        assign link_run=dut.u_core.u_link.lane_run[0];
        assign tx_ready=dut.u_core.u_link.tx_ready;
        assign solver_busy=dut.u_core.g_lane[0].g_par.u_solver.busy;
        assign solver_round=8'(dut.u_core.g_lane[0].g_par.u_solver.r);
        assign lane_avail=dut.u_core.lane_avail[0];
        assign lane_ack=dut.u_core.lane_ack[0];
        assign cmd_job=dut.u_core.u_link.cmd_job;
        assign cmd_stop=dut.u_core.u_link.cmd_stop;
        assign sending_sol=dut.u_core.u_link.sending_sol;
        assign bist_done=dut.u_core.lane_bd[0];
        assign bist_fail=dut.u_core.lane_bf[0];
        assign bist_running=dut.u_core.u_link.bist_running;
        assign mid_start=dut.u_core.mid_start;
        assign lane_start=dut.u_core.lane_start[0];
        assign tx_state=dut.u_core.u_link.ast;
        assign filter_drops=dut.u_core.g_lane[0].share_drops;
    end
    else begin : g_small
        zeq200_core #(.PAR_DROP_ZERO(DROP_ZERO),.PAR_LEAF_SET(LEAF_SET),.PAR_HASH_UNITS(HASH_UNITS),.PAR_GMAX(GMAX),.PAR_GROUP_REPLAY(GROUP_REPLAY),.N(N),.K(K),.LANES(1),.DIV(DIV),.HASH_SPLIT(HASH_SPLIT),.ARCH(1),.PAR_BB(BB),.PAR_PB(PB),.PAR_HPB(HPB),.PAR_SB(SB),
            .PAR_SLOTS(SLOTS),.PAR_BUCKET0_SLOTS(BUCKET0_SLOTS),.PAR_PACKED_TABLES(PACKED_TABLES),.PAR_STAGED_NETWORK(STAGED_NETWORK),.PAR_SPLIT_KEYS(1),.PAR_COMPACT_VALUES(1),.SHARE_FILTER(1),.BOOT_BIST(1)) dut (
            .clk(clk),.rst_n(rst_n),.rsto_n(rsto_n),.addr_strap(2'b00),.ci(ci),.co(co),
            .ri(ri),.ro(ro),.bi(bi),.bo(bo),.tsense(8'd60),.temp_pull(temp_pull),
            .val_req_valid(),.val_req_ready(1'b0),.val_req_we(),.val_req_addr(),.val_req_wdata(),
            .val_rsp_valid(1'b0),.val_rsp_rdata({N{1'b0}}),
            .ptr_req_valid(),.ptr_req_ready(1'b0),.ptr_req_we(),.ptr_req_addr(),.ptr_req_wdata(),
            .ptr_rsp_valid(1'b0),.ptr_rsp_rdata({(2*RW){1'b0}}),
            .ord_req_valid(),.ord_req_ready(1'b0),.ord_req_we(),.ord_req_addr(),.ord_req_wdata(),
            .ord_rsp_valid(1'b0),.ord_rsp_rdata({RW{1'b0}}));
        assign core_reset=dut.rst;
        assign link_state=dut.u_link.cst;
        assign builder_state=dut.u_link.bst;
        assign fifo_level=16'(dut.u_link.f_level);
        assign pending_done=dut.u_link.done_pend[0];
        assign link_room=dut.u_link.own_room;
        assign link_run=dut.u_link.lane_run[0];
        assign tx_ready=dut.u_link.tx_ready;
        assign solver_busy=dut.g_lane[0].g_par.u_solver.busy;
        assign solver_round=8'(dut.g_lane[0].g_par.u_solver.r);
        assign lane_avail=dut.lane_avail[0];
        assign lane_ack=dut.lane_ack[0];
        assign cmd_job=dut.u_link.cmd_job;
        assign cmd_stop=dut.u_link.cmd_stop;
        assign sending_sol=dut.u_link.sending_sol;
        assign bist_done=dut.lane_bd[0];
        assign bist_fail=dut.lane_bf[0];
        assign bist_running=dut.u_link.bist_running;
        assign mid_start=dut.mid_start;
        assign lane_start=dut.lane_start[0];
        assign tx_state=dut.u_link.ast;
        assign filter_drops=dut.g_lane[0].share_drops;
    end
    endgenerate
    reg [7:0] jobs[0:279];
    integer fd,coverage_fd,pongs=0,own_streams=0,forward_frames=0;
    integer done_d=0,done_e=0,rx_idx=0,rx_len=0;
    reg [7:0] rx_byte,rx_type,rx_addr,rx_job;
    integer rx_bit;
    integer bad_crc_ignored=0,generation_cancel=0,round_reset=0,bist_pass=0;
    integer backpressure_cycles=0,stop_during_solution=0,job_during_solution=0,saved_drops=0;
    integer bist_job_deferred=0,bist_stop_canceled=0;
    integer startup_bist_pass=0,reset_bist_pass=0;
    always @(posedge clk) if (!core_reset) begin
        if(bist_running && (mid_start || lane_start))$fatal(1,"BIST overlaps a mining launch");
        if (lane_avail && !lane_ack && tx_state==1) backpressure_cycles+=1;
        if (cmd_stop && sending_sol) stop_during_solution+=1;
        if (cmd_job && sending_sol) job_during_solution+=1;
    end
    function automatic [7:0] crc8(input [7:0] c,b);
        reg [7:0] x;
        integer i;
        begin
            x=c^b;
            for(i=0;i<8;i+=1) x=x[7]?((x<<1)^8'h07):(x<<1);
            crc8=x;
        end
    endfunction
    task automatic byte_out(input [7:0] b,input bit upstream);
        integer i;
        begin
            if(upstream)ri=0;else ci=0;
            #(BIT_NS);
            for(i=0;i<8;i+=1)begin
                if(upstream)ri=b[i];else ci=b[i];
                #(BIT_NS);
            end
            if(upstream)ri=1;else ci=1;
            #(BIT_NS);
        end
    endtask
    // header=-1 emits zeros; otherwise a JOB with id then selected header.
    task automatic command(input [7:0] typ,id,input integer len,header,input bit corrupt);
        reg [7:0] c,v;
        integer i;
        begin
            c=0;byte_out(8'ha5,0);
            byte_out(typ,0);c=crc8(c,typ);
            byte_out(0,0);c=crc8(c,0);
            byte_out(8'(len),0);c=crc8(c,8'(len));
            byte_out(8'(len>>8),0);c=crc8(c,8'(len>>8));
            for(i=0;i<len;i+=1)begin
                v=header<0?8'd0:(i==0?id:jobs[header*140+i-1]);
                byte_out(v,0);c=crc8(c,v);
            end
            byte_out(c^(corrupt?8'h01:8'h00),0);
        end
    endtask
    task automatic upstream_frame(input integer frame);
        reg [7:0] c,v;
        integer i,len;
        begin
            len=4+4*(1<<K);c=0;
            byte_out(8'h5a,1);
            byte_out(8'hf0,1);c=crc8(c,8'hf0);
            byte_out(8'h7e,1);c=crc8(c,8'h7e);
            byte_out(8'(len),1);c=crc8(c,8'(len));
            byte_out(8'(len>>8),1);c=crc8(c,8'(len>>8));
            for(i=0;i<len;i+=1)begin v=8'(i*29+frame*17);byte_out(v,1);c=crc8(c,v);end
            byte_out(c,1);
        end
    endtask
    initial begin
        fd=$fopen("core_rx.hex","w");
        forever begin
            @(negedge ro);#(BIT_NS*1.5);
            for(rx_bit=0;rx_bit<8;rx_bit+=1)begin rx_byte[rx_bit]=ro;#(BIT_NS);end
            $fwrite(fd,"%02x\n",rx_byte);$fflush(fd);
            if(rx_idx==1)rx_type=rx_byte;
            if(rx_idx==2)rx_addr=rx_byte;
            if(rx_idx==3)rx_len=32'(rx_byte);
            if(rx_idx==4)rx_len=rx_len|(32'(rx_byte)<<8);
            if(rx_idx==5)begin
                rx_job=rx_byte;
                if(rx_type==8'h81 && rx_addr==0)own_streams+=1;
            end
            rx_idx+=1;
            if(rx_idx>4 && rx_idx==rx_len+6)begin
                if(rx_addr==0 && rx_type==8'h84)pongs+=1;
                if(rx_addr==0 && rx_type==8'h85 && rx_job==8'h34)done_d+=1;
                if(rx_addr==0 && rx_type==8'h85 && rx_job==8'h35)done_e+=1;
                if(rx_addr==8'h7e)forward_frames+=1;
                rx_idx=0;
            end
        end
    end
    integer frame_i;
    integer stage=0;
    reg start_forwarding=0,forwarding_done=0;
    initial begin
        wait(start_forwarding);
        for(frame_i=0;frame_i<4;frame_i+=1)upstream_frame(frame_i);
        forwarding_done=1;
    end
    initial begin
        $readmemh("core_jobs.hex",jobs);
        repeat(10)@(negedge clk);rst_n=1;
        repeat(10)@(negedge clk);
        if(!bist_running || bo || solver_busy)$fatal(1,"startup memory test ownership missing");
        wait(bist_done && !bist_running);
        if(bist_fail)$fatal(1,"startup memory test failed");
        startup_bist_pass=1;
        repeat(10)@(negedge clk);
        command(8'h04,0,0,-1,0);wait(pongs==1);stage=1;
        command(8'h01,8'h30,141,0,1);
        repeat(100)@(negedge clk);
        if(solver_busy || !bo)$fatal(1,"bad-CRC job was accepted");bad_crc_ignored=1;
        command(8'h01,8'h31,141,0,0);
        wait(solver_busy && solver_round==0);
        command(8'h02,0,0,-1,0);wait(bo);generation_cancel=1;stage=2;
        command(8'h01,8'h32,141,0,0);
        wait(solver_busy && solver_round==1);
        #3 rst_n=0;repeat(6)@(negedge clk);rst_n=1;
        repeat(10)@(negedge clk);
        if(!bist_running || bo || solver_busy)$fatal(1,"reset bypassed memory requalification");
        wait(bist_done && !bist_running);
        if(bist_fail)$fatal(1,"reset memory requalification failed");
        reset_bist_pass=1;
        repeat(10)@(negedge clk);
        if(solver_busy || !bo)$fatal(1,"reset failed to clear active solver");round_reset=1;
        command(8'h04,0,0,-1,0);wait(pongs==2);stage=3;
        command(8'h06,0,0,-1,0);
        // Startup/recovery BIST has already left sticky DONE high. Observe
        // ownership of this new request before waiting for its completion.
        wait(bist_running);
        if(N==200)begin
            command(8'h01,8'h31,141,0,0);
            if(!bist_running || solver_busy)$fatal(1,"JOB did not wait for mainnet BIST");
            command(8'h02,0,0,-1,0);
            if(!bist_running)$fatal(1,"STOP aborted active memory BIST");
        end
        wait(bist_done && !bist_running);
        if(bist_fail)$fatal(1,"core BIST failed");bist_pass=1;
        repeat(20)@(negedge clk);
        if(solver_busy || !bo)$fatal(1,"BIST-time STOP did not cancel queued work");
        if(N==200)bist_stop_canceled=1;
        command(8'h04,0,0,-1,0);wait(pongs==3);stage=4;
        if(N==200)command(8'h06,0,0,-1,0);
        command(8'h01,8'h33,141,0,0);
        if(N==200)begin
            if(!bist_running || solver_busy)$fatal(1,"replacement JOB overlapped BIST");
            wait(bist_done && !bist_running);bist_job_deferred=1;
            if(bist_fail)$fatal(1,"replacement mainnet BIST failed");
        end
        wait(solver_busy && solver_round==8'(K));start_forwarding=1;
        wait(own_streams>0);stage=5;
        command(8'h02,0,0,-1,0);
        command(8'h01,8'h34,141,1,0);
        stage=6;wait(done_d>0);stage=7;command(8'h02,0,0,-1,0);wait(bo);stage=8;
        wait(forwarding_done && forward_frames==4);stage=9;
        command(8'h05,0,32,-1,0); // zero share target
        command(8'h01,8'h35,141,0,0);
        stage=10;wait(done_e>0);saved_drops=32'(filter_drops);stage=11;
        command(8'h02,0,0,-1,0);wait(bo);
        #(BIT_NS*100);
        if(rx_idx!=0)$fatal(1,"partial packet at end of test");
        $fclose(fd);
        coverage_fd=$fopen("coverage.txt","w");
        $fwrite(coverage_fd,"bad_crc_ignored %0d\ngeneration_cancel %0d\nround_reset %0d\nbist_pass %0d\nbackpressure_cycles %0d\nstop_during_solution %0d\njob_during_solution %0d\nfilter_drops %0d\n",bad_crc_ignored,generation_cancel,round_reset,bist_pass,backpressure_cycles,stop_during_solution,job_during_solution,saved_drops);
        $fwrite(coverage_fd,"bist_job_deferred %0d\nbist_stop_canceled %0d\n",bist_job_deferred,bist_stop_canceled);
        $fwrite(coverage_fd,"startup_bist_pass %0d\nreset_bist_pass %0d\n",startup_bist_pass,reset_bist_pass);
        $fclose(coverage_fd);
        $display("core control N=%0d K=%0d: simulation completed; independent packet checks required",N,K);
        $finish;
    end
    initial begin
        if(N==200) #2_000_000_000;
        else #10_000_000;
        $display("link cst=%0d ast=%0d bst=%0d fifo=%0d pending=%b room=%b run=%b tx_ready=%b",link_state,tx_state,builder_state,fifo_level,pending_done,link_room,link_run,tx_ready);
        $fatal(1,"core-control TIMEOUT stage=%0d bo=%b busy=%b round=%0d forwards=%0d forwarding_done=%b done_d=%0d done_e=%0d",stage,bo,solver_busy,solver_round,forward_frames,forwarding_done,done_d,done_e);
    end
endmodule
