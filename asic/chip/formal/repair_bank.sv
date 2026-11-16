// Adapter control/remapping contract. Physical read data is unconstrained.
// Memory-cell behavior and BIST fault coverage are checked separately.
module repair_bank_formal #(
    parameter integer AW=3, DW=13, DEPTH=5, PAW=$clog2(DEPTH+1)
) (
    input wire clk, rst, maintenance, we, re, repair_load, repair_enable, bist_start,
    input wire [AW-1:0] waddr, raddr, repair_addr,
    input wire [DW-1:0] wdata, mem_rdata
);
    wire [DW-1:0] rdata, mem_wdata;
    wire app_ready, repair_ready, repair_active, control_error;
    wire bist_ready, bist_active, bist_done, bist_fail;
    wire fail_valid, fail_multirow;
    wire [AW-1:0] repair_row, fail_addr;
    wire [DW-1:0] fail_expected, fail_observed;
    wire [2:0] fail_element;
    wire mem_we, mem_re;
    wire [PAW-1:0] mem_waddr, mem_raddr;
    zeq_repair_bank #(.AW(AW),.DW(DW),.DEPTH(DEPTH)) dut (.*);

    reg past_valid=0, enabled, error;
    reg [AW-1:0] row;
    wire valid_addresses=(!we || 32'(waddr)<DEPTH) && (!re || 32'(raddr)<DEPTH);
    wire config_idle=!rst && maintenance && !bist_active && !bist_start && !we && !re;
    wire test_idle=!rst && maintenance && !bist_active && !repair_load && !we && !re;
    wire normal=!rst && !maintenance && !bist_active && !repair_load && !bist_start && valid_addresses;
    always @(posedge clk) begin
        past_valid<=1;
        if(!past_valid) assume(rst);
        if(rst) begin enabled<=0;row<=0;error<=0;end
        else begin
            if(repair_load) begin
                if(config_idle && (!repair_enable || 32'(repair_addr)<DEPTH)) begin
                    enabled<=repair_enable;
                    row<=repair_enable ? repair_addr : {AW{1'b0}};
                    error<=0;
                end else error<=1;
            end
            if((bist_start && !test_idle) || ((we || re) && !valid_addresses)) error<=1;
        end
        if(past_valid) begin
            assert(repair_active==enabled && repair_row==row && control_error==error);
            assert(app_ready==normal && repair_ready==config_idle && bist_ready==test_idle);
            if(enabled) assert(32'(row)<DEPTH);
            assert(rdata==mem_rdata);
            if(rst) assert(!mem_we && !mem_re);
            if(!bist_active) begin
                assert(mem_we==(we && normal));
                assert(mem_re==(re && normal));
                if(mem_we) begin
                    assert(mem_wdata==wdata);
                    assert(mem_waddr==(enabled && waddr==row ? PAW'(DEPTH) : PAW'(waddr)));
                    assert(32'(mem_waddr)<=DEPTH);
                end
                if(mem_re) begin
                    assert(mem_raddr==(enabled && raddr==row ? PAW'(DEPTH) : PAW'(raddr)));
                    assert(32'(mem_raddr)<=DEPTH);
                end
                if(mem_we && mem_re)
                    assert((mem_waddr==mem_raddr)==(waddr==raddr));
            end
            if($past(repair_load && config_idle && (!repair_enable || 32'(repair_addr)<DEPTH)))
                assert(!bist_done); // A changed configuration cannot inherit PASS.
        end
    end
endmodule
