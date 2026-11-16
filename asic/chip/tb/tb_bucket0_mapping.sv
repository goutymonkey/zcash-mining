// Exhaust the actual solver address functions over every valid logical row.
// Expected addresses come from walking consecutive physical locations, not
// from duplicating the compressed-address expression under test.
module tb_bucket0_mapping;
    parameter integer N=48, K=5, BB=4, PB=2, SB=7, SLOTS=80, BUCKET0_SLOTS=112;
    localparam integer JB=BB-PB, P=1<<PB, BPE=1<<JB;
    zeq_eh_par #(.N(N),.K(K),.BB(BB),.PB(PB),.SB(SB),.SLOTS(SLOTS),
        .BUCKET0_SLOTS(BUCKET0_SLOTS),.PACKED_TABLES(1),.SPLIT_KEYS(1),
        .COMPACT_VALUES(1)) dut (
        .clk(1'b0),.rst(1'b1),.hdr(1120'b0),.mid_start(1'b0),.mid_done(),
        .start(1'b0),.cancel(1'b0),.busy(),.done(),.nsol(),.dropped(),
        .sol_avail(),.sol_ack(1'b0),.bist_start(1'b0),.bist_done(),.bist_fail(),
        .sol_raddr({K{1'b0}}),.sol_rdata());
    integer bank, bucket, slot, level, limit, address, total, checked;
    integer logical_row;
    initial begin
        checked=0;
        for (bank=0;bank<P;bank=bank+1) begin
            total=0;
            for (bucket=0;bucket<BPE;bucket=bucket+1)
                total=total+((bank==0 && bucket==0)?BUCKET0_SLOTS:SLOTS);
            address=0;
            for (bucket=0;bucket<BPE;bucket=bucket+1) begin
                limit=(bank==0 && bucket==0)?BUCKET0_SLOTS:SLOTS;
                for (slot=0;slot<limit;slot=slot+1) begin
                    logical_row=(bucket<<SB)|slot;
                    if (int'(dut.row_addr((JB+SB)'(logical_row),PB'(bank))) != address)
                        $fatal(1,"row mapping bank=%0d bucket=%0d slot=%0d expected=%0d",bank,bucket,slot,address);
                    for (level=1;level<K;level=level+1)
                        if (int'(dut.paddr_of($clog2(K+1)'(level),(JB+SB)'(logical_row),PB'(bank))) != (level-1)*total+address)
                            $fatal(1,"parent level alias bank=%0d level=%0d row=%0d",bank,level,address);
                    address=address+1;
                    checked=checked+1;
                end
            end
            if (address!=total) $fatal(1,"physical row coverage mismatch");
        end
        $display("bucket-zero mapping PASS: %0d rows, %0d parent levels, %0d banks",checked,K-1,P);
        $finish;
    end
endmodule
