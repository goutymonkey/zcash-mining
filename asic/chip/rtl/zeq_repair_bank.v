// Technology-independent one-spare-row SRAM adapter and diagnostic BIST.
// Physical memory must provide DEPTH+1 rows and one-cycle, old-data 1W1R.
// Configuration is volatile: a future fuse/scan/CSR loader must replay it.
// This candidate is not wired into the production top or a compiler macro.
`default_nettype none
module zeq_repair_bank #(
    parameter integer AW=8, DW=32, DEPTH=1<<AW,
    parameter integer PAW=$clog2(DEPTH+1)
) (
    input wire clk, rst,
    input wire maintenance,
    input wire we, re,
    input wire [AW-1:0] waddr, raddr,
    input wire [DW-1:0] wdata,
    output wire [DW-1:0] rdata,
    output wire app_ready,
    input wire repair_load, repair_enable,
    input wire [AW-1:0] repair_addr,
    output wire repair_ready,
    output reg repair_active,
    output reg [AW-1:0] repair_row,
    output reg control_error,
    input wire bist_start,
    output wire bist_ready, bist_active, bist_done, bist_fail,
    output wire fail_valid,
    output wire [AW-1:0] fail_addr,
    output wire [DW-1:0] fail_expected, fail_observed,
    output wire [2:0] fail_element,
    output wire fail_multirow,
    output wire mem_we, mem_re,
    output wire [PAW-1:0] mem_waddr, mem_raddr,
    output wire [DW-1:0] mem_wdata,
    input wire [DW-1:0] mem_rdata
);
    localparam [PAW-1:0] SPARE = PAW'(DEPTH);
    wire b_we, b_re, b_pass, b_done;
    reg test_valid, b_done_q;
    wire [AW-1:0] b_waddr, b_raddr;
    wire [DW-1:0] b_wdata;
    wire address_ok = (!we || 32'(waddr)<DEPTH) && (!re || 32'(raddr)<DEPTH);
    assign app_ready = !rst && !maintenance && !bist_active && !repair_load && !bist_start && address_ok;
    assign repair_ready = !rst && maintenance && !bist_active && !bist_start && !we && !re;
    assign bist_ready = !rst && maintenance && !bist_active && !repair_load && !we && !re;
    wire load_ok = repair_ready && (!repair_enable || 32'(repair_addr)<DEPTH);
    always @(posedge clk) begin
        if (rst) begin
            repair_active<=0; repair_row<=0; control_error<=0;
            test_valid<=0; b_done_q<=0;
        end else begin
            b_done_q<=b_done;
            if(b_done && !b_done_q) test_valid<=1;
            if(bist_start && bist_ready) test_valid<=0;
            if (repair_load) begin
                if (load_ok) begin
                    repair_active<=repair_enable;
                    repair_row<=repair_enable ? repair_addr : {AW{1'b0}};
                    control_error<=0;
                    test_valid<=0; // A configuration change always requires retest.
                end else control_error<=1;
            end
            if ((bist_start && !bist_ready) || ((we || re) && !address_ok))
                control_error<=1;
        end
    end
    zeq_mbist #(.AW(AW),.DW(DW),.DEPTH(DEPTH)) u_bist (
        .clk(clk),.rst(rst),.start(bist_start && bist_ready),
        .active(bist_active),.done(b_done),.pass(b_pass),
        .we(b_we),.waddr(b_waddr),.wdata(b_wdata),.re(b_re),.raddr(b_raddr),.rdata(mem_rdata),
        .fail_valid(fail_valid),.fail_addr(fail_addr),.fail_expected(fail_expected),
        .fail_observed(fail_observed),.fail_element(fail_element),.fail_multirow(fail_multirow));
    assign bist_done=b_done && test_valid;
    assign bist_fail=bist_done && !b_pass;
    wire [AW-1:0] wa = bist_active ? b_waddr : waddr;
    wire [AW-1:0] ra = bist_active ? b_raddr : raddr;
    assign mem_we = !rst && (bist_active ? b_we : we && app_ready);
    assign mem_re = !rst && (bist_active ? b_re : re && app_ready);
    assign mem_waddr = repair_active && wa==repair_row ? SPARE : PAW'(wa);
    assign mem_raddr = repair_active && ra==repair_row ? SPARE : PAW'(ra);
    assign mem_wdata = bist_active ? b_wdata : wdata;
    assign rdata = mem_rdata;
`ifndef SYNTHESIS
    initial if(AW<1 || DW<1 || DEPTH<1 || DEPTH>(1<<AW) || PAW<$clog2(DEPTH+1))
        $fatal(1,"invalid repair bank geometry");
    generate if(DEPTH+1<(1<<PAW)) begin : g_bounds
        always @(posedge clk) if(!rst) begin
            if(mem_we && 32'(mem_waddr)>DEPTH) $fatal(1,"physical write out of range");
            if(mem_re && 32'(mem_raddr)>DEPTH) $fatal(1,"physical read out of range");
        end
    end endgenerate
`endif
endmodule
`default_nettype wire
