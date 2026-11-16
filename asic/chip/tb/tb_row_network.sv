module tb_row_network;
    parameter integer PB=4,DW=232,CYCLES=4096;
    localparam integer P=1<<PB, MAX_IDS=P*(CYCLES+1)+1;
    reg clk=0,rst=1,cancel=0;
    always #5 clk=~clk;
    reg [P-1:0] in_valid=0;
    reg [P*PB-1:0] in_target=0;
    reg [P*DW-1:0] in_data=0;
    wire [P-1:0] in_take,out_valid;
    wire [P*DW-1:0] out_data;
    wire idle;
    zeq_row_network #(.PB(PB),.DW(DW)) dut (.*);
    reg [DW-1:0] expected[0:MAX_IDS-1];
    integer destinations[0:MAX_IDS-1];
    // 0: not accepted, 1: outstanding, 2: delivered, 3: flushed.
    integer state[0:MAX_IDS-1];
    integer age[0:P-1];
    reg [P-1:0] accepted_mask=0;
    integer next_id=1,accepted=0,delivered=0,flushed=0,stalls=0,max_age=0;
    integer i,j,id;
    always @(posedge clk) begin
        accepted_mask=in_take;
        if(rst || cancel) begin
            if(in_take!=0 || out_valid!=0 || !idle) $fatal(1,"traffic during clear");
            for(i=1;i<next_id;i+=1) if(state[i]==1) begin state[i]=3;flushed+=1;end
            for(i=0;i<P;i+=1) age[i]=0;
        end else begin
            for(i=0;i<P;i+=1) begin
                if(out_valid[i]) begin
                    id=32'(out_data[i*DW +: 32]);
                    if(id<1 || id>=next_id) $fatal(1,"unissued output token");
                    if(state[id]!=1 || destinations[id]!=i || out_data[i*DW +: DW]!==expected[id])
                        $fatal(1,"duplicate, corrupted, misrouted or canceled token id=%0d bank=%0d state=%0d",id,i,state[id]);
                    state[id]=2;delivered+=1;
                end
                if(in_take[i]) begin
                    id=32'(in_data[i*DW +: 32]);
                    if(!in_valid[i] || state[id]!=0) $fatal(1,"invalid/duplicate input acceptance");
                    state[id]=1;accepted+=1;age[i]=0;
                end else if(in_valid[i]) begin
                    age[i]+=1;stalls+=1;
                    if(age[i]>max_age) max_age=age[i];
                    if(age[i]>P+(1<<(PB-PB/2))+2) $fatal(1,"persistent source starved");
                end else age[i]=0;
            end
        end
    end
    reg [31:0] random_state=32'h19760929;
    function automatic [31:0] advance(input [31:0] x);
        reg [31:0] y;
        begin y=x^(x<<13);y=y^(y>>17);advance=y^(y<<5);end
    endfunction
    integer cycle,port,bank,word_index,drain;
    reg [DW-1:0] payload;
    initial begin
        repeat(3)@(negedge clk);rst=0;
        for(cycle=0;cycle<CYCLES;cycle+=1) begin
            @(negedge clk);
            cancel=(cycle%997==996);
            if(cancel) in_valid=0;
            else for(port=0;port<P;port+=1) begin
                if(accepted_mask[port]) in_valid[port]=0;
                random_state=advance(random_state);
                if(!in_valid[port] && (cycle<CYCLES/2 || random_state[1:0]!=0)) begin
                    // Hotspot, deterministic permutation, then uniform traffic.
                    bank=cycle<CYCLES/4?0:(cycle<CYCLES/2?((port+cycle)%P):32'(random_state[PB-1:0]));
                    payload=0;
                    for(word_index=0;word_index<(DW+31)/32;word_index+=1) begin
                        random_state=advance(random_state);payload=(payload<<32)|DW'(random_state);
                    end
                    payload[31:0]=32'(next_id);
                    expected[next_id]=payload;destinations[next_id]=bank;state[next_id]=0;
                    in_data[port*DW +: DW]=payload;in_target[port*PB +: PB]=PB'(bank);
                    in_valid[port]=1;next_id+=1;
                end
            end
        end
        // Drain producers first, then the elastic links. No accepted row lost.
        drain=0;
        while(in_valid!=0 || !idle) begin
            @(negedge clk);cancel=0;
            in_valid=in_valid & ~accepted_mask;
            drain+=1;if(drain>4*P+8)$fatal(1,"network failed to drain");
        end
        @(negedge clk);
        if(accepted!=delivered+flushed || delivered==0 || flushed==0 || stalls==0)
            $fatal(1,"conservation/coverage failure: accepted=%0d delivered=%0d flushed=%0d",accepted,delivered,flushed);
        for(j=1;j<next_id;j+=1)if(state[j]==1)$fatal(1,"outstanding token at end");
        $display("row network PB=%0d DW=%0d PASS accepted=%0d delivered=%0d flushed=%0d stalls=%0d max_wait=%0d",PB,DW,accepted,delivered,flushed,stalls,max_age);
        $finish;
    end
    initial #1_000_000 $fatal(1,"row network timeout");
endmodule
