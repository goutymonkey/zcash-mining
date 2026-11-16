// Adversarial pair-set oracle independent of the block/replay schedule.
module tb_group_replay;
    parameter integer BUFFER=8;
    localparam integer AW=6, DW=16, KW=6;
    reg clk=0;
    always #5 clk=~clk;
    reg rst=1, cancel=0, start=0, ready=0, row_valid=0;
    reg [AW:0] count=0;
    reg [AW-1:0] row_slot=0;
    reg [KW-1:0] row_key=0;
    reg [DW-1:0] row_value=0;
    wire rd, valid, done;
    wire [AW-1:0] rindex, slot_a, slot_b;
    wire [DW-1:0] pair_xor;
    zeq_replay_pairs #(.AW(AW),.DW(DW),.KW(KW),.BUFFER(BUFFER)) dut (.*);
    integer keys[0:63], slots[0:63], inverse[0:63], values[0:63];
    bit seen[0:63][0:63];
    integer cycle=0, delay_left=0, pending_index=0, reads=0, pairs=0;
    bit pending=0, stalled=0;
    reg [2*AW+DW-1:0] held;
    // Variable-latency one-outstanding memory, invalidated on reset/cancel.
    always @(posedge clk) begin
        cycle <= cycle+1;
        row_valid <= 0;
        if (rst || cancel) begin pending<=0; stalled<=0; end
        else begin
            if (rd) begin
                if (pending || int'(rindex)>=int'(count)) $fatal(1,"invalid read");
                pending<=1; pending_index<=int'(rindex); delay_left<=cycle%4+1;
                reads<=reads+1;
            end
            if (pending) begin
                if (delay_left==0) begin
                    row_valid<=1; pending<=0;
                    row_key<=KW'(keys[pending_index]);
                    row_slot<=AW'(slots[pending_index]);
                    row_value<=DW'(values[slots[pending_index]]);
                end else delay_left<=delay_left-1;
            end
            if (stalled && (!valid || {slot_a,slot_b,pair_xor}!=held))
                $fatal(1,"output changed under backpressure");
            stalled<=valid && !ready;
            held<={slot_a,slot_b,pair_xor};
            if (valid && ready) begin
                if (inverse[slot_a]>=inverse[slot_b] || keys[inverse[slot_a]]!=keys[inverse[slot_b]])
                    $fatal(1,"wrong pair");
                if (seen[slot_a][slot_b]) $fatal(1,"duplicate pair");
                if (pair_xor!=DW'(values[slot_a]^values[slot_b])) $fatal(1,"wrong XOR");
                seen[slot_a][slot_b]<=1; pairs<=pairs+1;
            end
        end
    end
    task setup_case(input integer n, input integer mode);
        integer i,j;
        begin
            count=7'(n); reads=0; pairs=0;
            for(i=0;i<64;i=i+1) begin
                slots[i]=(13*i+7)%64; inverse[slots[i]]=i;
                // Deliberately equal values with different slot ancestry.
                values[slots[i]]=i%3;
                case(mode)
                    0:keys[i]=0;
                    1:keys[i]=i;
                    2:keys[i]=i/3;
                    default:keys[i]=i<33 ? 0 : (i<35 ? 1 : 2);
                endcase
                for(j=0;j<64;j=j+1) seen[i][j]=0;
            end
        end
    endtask
    task run_case(input integer n, input integer mode);
        integer i,j,expected,watchdog;
        begin
            @(negedge clk); setup_case(n,mode); start=1;
            @(negedge clk); start=0; watchdog=0;
            while(!done) begin
                ready=(cycle%7>=3); watchdog=watchdog+1;
                if(watchdog>100000) $fatal(1,"timeout");
                @(negedge clk);
            end
            expected=0;
            for(i=0;i<n;i=i+1) for(j=i+1;j<n;j=j+1) if(keys[i]==keys[j]) begin
                expected=expected+1;
                if(!seen[slots[i]][slots[j]]) $fatal(1,"missing pair");
            end
            if(pairs!=expected) $fatal(1,"pair count");
            if(n==64 && mode==0 && reads<=64) $fatal(1,"replay not exercised");
            @(negedge clk);
        end
    endtask
    task abort_case(input bit reset_it, input bit on_pair);
        begin
            @(negedge clk); setup_case(64,0); ready=0; start=1;
            @(negedge clk); start=0;
            if(on_pair) begin while(!valid) @(negedge clk); end
            else begin while(!pending) @(negedge clk); end
            if(reset_it) rst=1; else cancel=1;
            @(negedge clk); rst=0; cancel=0;
            repeat(8) begin
                @(negedge clk);
                if(valid || rd || done) $fatal(1,"stale work after abort");
            end
        end
    endtask
    integer n,m;
    initial begin
        repeat(3) @(negedge clk);
        rst=0;
        for(m=0;m<4;m=m+1) for(n=0;n<=64;n=n+1) run_case(n,m);
        abort_case(0,0); run_case(35,3);
        abort_case(0,1); run_case(64,0);
        abort_case(1,0); run_case(17,2);
        abort_case(1,1); run_case(64,3);
        $display("group replay BUFFER=%0d: PASS (264 complete cases, 4 abort/restart cases)",BUFFER);
        $finish;
    end
    initial begin #200000000; $fatal(1,"global timeout"); end
endmodule
