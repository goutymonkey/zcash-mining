`timescale 1ns/1ps
module tb_repair_bank;
    parameter integer AW=3, DW=13, DEPTH=5;
    localparam integer PAW=$clog2(DEPTH+1), BAD=DEPTH/2;
    reg clk=0, rst=1, maintenance=1, we=0, re=0;
    always #5 clk=~clk;
    reg [AW-1:0] waddr=0, raddr=0, repair_addr=0;
    reg [DW-1:0] wdata=0;
    reg repair_load=0, repair_enable=0, bist_start=0;
    wire [DW-1:0] rdata, mem_wdata, fail_expected, fail_observed;
    wire app_ready, repair_ready, repair_active, control_error;
    wire bist_ready, bist_active, bist_done, bist_fail, fail_valid, fail_multirow;
    wire mem_we, mem_re;
    wire [AW-1:0] repair_row, fail_addr;
    wire [PAW-1:0] mem_waddr, mem_raddr;
    wire [2:0] fail_element;
    reg [DW-1:0] mem_rdata=0;
    reg [DW-1:0] physical [0:DEPTH];
    reg bad_row=0, bad_spare=0, second_bad=0;
    integer writes=0;
    zeq_repair_bank #(.AW(AW),.DW(DW),.DEPTH(DEPTH)) dut (.*);

    // Independent old-data physical SRAM model, including the spare row.
    always @(posedge clk) begin
        if(mem_we) begin
            physical[mem_waddr]<=mem_wdata;
            writes<=writes+1;
        end
        if(mem_re) begin
            mem_rdata<=physical[mem_raddr];
            if((bad_row && 32'(mem_raddr)==BAD) ||
               (bad_spare && 32'(mem_raddr)==DEPTH) ||
               (second_bad && mem_raddr==0)) mem_rdata[0]<=1'b1;
        end
    end
    task cycle;
        @(posedge clk); #1;
    endtask
    task load_repair(input bit enable, input integer row);
        maintenance=1; #1;
        if(!repair_ready) $fatal(1,"repair interface unexpectedly busy");
        repair_enable=enable; repair_addr=AW'(row); repair_load=1;
        cycle(); repair_load=0; #1;
        if(control_error || repair_active!=enable || (enable && repair_row!=AW'(row)))
            $fatal(1,"configuration did not load");
        if(bist_done) $fatal(1,"configuration change retained stale BIST qualification");
    endtask
    task start_test;
        maintenance=1; #1;
        if(!bist_ready) $fatal(1,"BIST not ready");
        bist_start=1; cycle(); bist_start=0;
        if(!bist_active || app_ready || repair_ready) $fatal(1,"test ownership broken");
    endtask
    task finish_test(input bit failing);
        integer timeout;
        timeout=0;
        while(!bist_done && timeout<DEPTH*40+100) begin cycle(); timeout=timeout+1; end
        if(!bist_done || bist_fail!=failing || fail_valid!=failing)
            $fatal(1,"BIST result/diagnostic mismatch fail=%0d done=%0d actual=%0d",failing,bist_done,bist_fail);
    endtask
    task test_memory(input bit failing);
        start_test(); finish_test(failing);
    endtask
    task write_word(input integer addr, input reg [DW-1:0] value);
        maintenance=0; waddr=AW'(addr); wdata=value; we=1; #1;
        if(!app_ready) $fatal(1,"normal write not ready");
        cycle(); we=0;
    endtask
    task read_word(input integer addr, input reg [DW-1:0] expected);
        maintenance=0; raddr=AW'(addr); re=1; #1;
        if(!app_ready) $fatal(1,"normal read not ready");
        cycle(); re=0;
        if(rdata!==expected) $fatal(1,"read mismatch addr=%0d got=%h expected=%h",addr,rdata,expected);
    endtask
    integer i, before_writes;
    reg [DW-1:0] held;
    initial begin
        repeat(3) cycle(); rst=0; cycle();
        test_memory(0);
        if(fail_multirow) $fatal(1,"healthy multirow flag");

        bad_row=1;
        test_memory(1);
        if(fail_addr!=AW'(BAD) || fail_expected!=0 || fail_observed!=DW'(1)
           || fail_element!=1 || fail_multirow) $fatal(1,"wrong first-failure diagnosis");
        repeat(4) cycle();
        if(fail_addr!=AW'(BAD) || fail_observed!=DW'(1)) $fatal(1,"diagnostic not sticky");

        load_repair(1,BAD);
        test_memory(0);
        if(physical[DEPTH]!==0) $fatal(1,"spare was not tested by logical BIST");
        for(i=0;i<DEPTH;i=i+1) write_word(i,DW'(i*19+6));
        for(i=0;i<DEPTH;i=i+1) read_word(i,DW'(i*19+6));
        if(physical[DEPTH]!==DW'(BAD*19+6)) $fatal(1,"repaired row was not mapped to spare");

        // Both ports must remap together and retain old-data collision timing.
        waddr=AW'(BAD);raddr=AW'(BAD);wdata=DW'(42);we=1;re=1;
        cycle();we=0;re=0;
        if(rdata!==DW'(BAD*19+6)) $fatal(1,"read-during-write did not return old data");
        read_word(BAD,DW'(42));held=rdata;
        repeat(3) cycle();
        if(rdata!==held) $fatal(1,"read output failed to hold");

        // A repair request cannot take effect while normal traffic is offered.
        repair_enable=0;repair_load=1;we=1;before_writes=writes;
        cycle();repair_load=0;we=0;
        if(!control_error || !repair_active || writes!=before_writes)
            $fatal(1,"unsafe configuration request accepted");
        load_repair(1,BAD);
        start_test();
        repair_enable=0;repair_load=1;bist_start=1;
        cycle();repair_load=0;bist_start=0;
        if(!control_error || !repair_active) $fatal(1,"active test accepted configuration/restart");
        finish_test(0);

        if(DEPTH<(1<<AW)) begin
            maintenance=1;repair_enable=1;repair_addr=AW'(DEPTH);repair_load=1;
            cycle();repair_load=0;
            if(!control_error || repair_row!=AW'(BAD)) $fatal(1,"invalid repair row accepted");
            maintenance=0;waddr=AW'(DEPTH);we=1;before_writes=writes;
            cycle();we=0;
            if(!control_error || writes!=before_writes) $fatal(1,"padding address write accepted");
        end

        load_repair(1,BAD);bad_spare=1;
        test_memory(1);
        if(fail_addr!=AW'(BAD)) $fatal(1,"spare defect lost logical address");
        bad_spare=0;
        load_repair(0,0);
        test_memory(1); // Disabling the mapping exposes the original defect.
        if(DEPTH>1) begin
            second_bad=1;test_memory(1);
            if(!fail_multirow) $fatal(1,"multiple defective rows not diagnosed");
            second_bad=0;
        end

        // Reset during test cancels traffic and discards volatile repair data.
        load_repair(1,BAD);start_test();repeat(5) cycle();rst=1;#1;
        if(mem_we || mem_re) $fatal(1,"reset failed to suppress physical traffic");
        cycle();rst=0;cycle();
        if(bist_active || bist_done || repair_active || fail_valid || control_error)
            $fatal(1,"reset left stale test/configuration state");
        bad_row=0;test_memory(0);
        $display("repair bank PASS AW=%0d DW=%0d DEPTH=%0d: diagnosis, remap, collision, faults, retest, ownership, reset",AW,DW,DEPTH);
        $finish;
    end
    initial begin #10000000; $fatal(1,"repair test timeout"); end
endmodule
