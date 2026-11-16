// The runner exposes the real link's decoded command strobes as symbolic
// inputs. UART decoding is checked by tb_link_bist.sv. This proof concerns
// scheduling/ownership, not serial framing, SRAM faults or analog behavior.
module link_bist_formal #(
    parameter integer BOOT_BIST=0
) (
    input wire clk,rst,cmd_job,cmd_stop,cmd_bist,bist_done,bist_fail,mid_done,
    input wire lane_done,lane_avail
);
    wire mid_start,lane_start,bist_start,bist_running,bist_armed,bist_fault,bist_pending;
    wire [1:0] cst;
    wire lane_run,job_req;
    link_control dut (
        .clk(clk),.rst(rst),.addr_strap(2'b00),.ci(1'b1),.co(),
        .ri(1'b1),.ro(),.bi(1'b1),.bo(),.tsense(8'd30),.temp_pull(),
        .hdr_eff(),.mid_start(mid_start),.mid_done(mid_done),
        .lane_start(lane_start),.lane_abort(),.lane_done(lane_done),
        .lane_nsol(8'd0),.lane_avail(lane_avail),.lane_ack(),.sol_raddr(),
        .lane_rdata(10'd0),.target_be(),.bist_start(bist_start),
        .bist_done(bist_done),.bist_fail(bist_fail),
        .cmd_job(cmd_job),.cmd_stop(cmd_stop),.cmd_bist(cmd_bist),
        .bist_running(bist_running),.bist_armed(bist_armed),.bist_fault(bist_fault),
        .bist_pending(bist_pending),
        .cst(cst),.lane_run(lane_run),.job_req(job_req));
    reg past_valid=0,open_test,seen_low,failed,boot_required;
    always @(posedge clk) begin
        past_valid<=1;
        if(!past_valid)assume(rst);
        if(rst)begin open_test<=0;seen_low<=0;failed<=0;boot_required<=BOOT_BIST!=0;end
        else begin
            if(bist_start)begin open_test<=1;seen_low<=!bist_done;end
            else if(open_test)begin
                if(!bist_done)seen_low<=1;
                if(seen_low && bist_done)begin
                    open_test<=0;seen_low<=0;failed<=bist_fail;
                    if(!bist_fail)boot_required<=0;
                end
            end
        end
        if(past_valid && !rst)begin
            if(boot_required)begin
                assert(bist_pending || bist_running || bist_fault);
                assert(!mid_start && !lane_start);
            end
            if(bist_pending)assert(!mid_start && !lane_start);
            // Prove the monitor/state relation as an invariant, rather than
            // assuming it. This excludes arbitrary induction states where
            // the monitor remembers a failure that the DUT never observed.
            assert(open_test==(bist_running && !bist_start));
            assert(seen_low==bist_armed);
            assert(failed==bist_fault);
            if(seen_low)assert(open_test);
            if(bist_start)assert(bist_running && !bist_armed);
            // Independent monitor starts at the memory request boundary;
            // an old sticky DONE cannot release it without a low observation.
            if(open_test)assert(!bist_start);
            if(bist_start || open_test || failed)assert(!mid_start && !lane_start);
            // Reachable-state invariants support induction across arbitrary
            // command, lane-completion and memory-response interleavings.
            if(bist_running || bist_fault)assert(cst==0 && !lane_run);
            if(open_test && !bist_start)assert(bist_running || (seen_low && bist_done) || failed);
            if($past(cmd_stop && !rst))assert(!job_req);
        end
    end
endmodule
