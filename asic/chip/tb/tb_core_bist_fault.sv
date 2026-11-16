// Behavioral RAM read-output stuck-at faults through the complete small core.
// No physical SRAM defect coverage or production-scale claim.
module tb_core_bist_fault;
    parameter integer PACKED_TABLES=0;
    localparam integer DIV=8;
    reg clk=0,rst_n=0,ci=1;
    always #5 clk=~clk;
    wire co,ro,bo,rsto_n,temp_pull;
    zeq200_core #(.N(48),.K(5),.LANES(1),.DIV(DIV),.ARCH(1),.PAR_BB(4),
        .PAR_PB(2),.PAR_SB(7),.PAR_SLOTS(80),.PAR_PACKED_TABLES(PACKED_TABLES),
        .PAR_SPLIT_KEYS(1),.PAR_COMPACT_VALUES(1),.SHARE_FILTER(1),.BOOT_BIST(1)) dut (
        .clk(clk),.rst_n(rst_n),.rsto_n(rsto_n),.addr_strap(2'b00),.ci(ci),.co(co),
        .ri(1'b1),.ro(ro),.bi(1'b1),.bo(bo),.tsense(8'd30),.temp_pull(temp_pull),
        .val_req_valid(),.val_req_ready(1'b0),.val_req_we(),.val_req_addr(),.val_req_wdata(),
        .val_rsp_valid(1'b0),.val_rsp_rdata(48'd0),
        .ptr_req_valid(),.ptr_req_ready(1'b0),.ptr_req_we(),.ptr_req_addr(),.ptr_req_wdata(),
        .ptr_rsp_valid(1'b0),.ptr_rsp_rdata(20'd0),
        .ord_req_valid(),.ord_req_ready(1'b0),.ord_req_we(),.ord_req_addr(),.ord_req_wdata(),
        .ord_rsp_valid(1'b0),.ord_rsp_rdata(10'd0));

    integer bank=-1,launches=0;
    reg inject=0;
    // Deposit at the read register after each RAM clock. No BIST result or
    // aggregate is forced: the real March engine must detect the bad data.
    always @(negedge clk) if(inject) case(bank)
        0: dut.g_lane[0].g_par.u_solver.g_eng[0].m_idx.q=0;
        1: dut.g_lane[0].g_par.u_solver.g_eng[3].m_idx.q=0;
        2: dut.g_lane[0].g_par.u_solver.g_eng[3].m_hist0.q=0;
        3: dut.g_lane[0].g_par.u_solver.g_eng[3].m_hist1.q=0;
        4: dut.g_lane[0].g_par.u_solver.g_eng[3].m_order.q=0;
        5: dut.g_lane[0].g_par.u_solver.g_eng[3].g_split_keys.m_key0.q=0;
        6: dut.g_lane[0].g_par.u_solver.g_eng[3].g_split_keys.m_key1.q=0;
        default: ;
    endcase
    generate if(PACKED_TABLES==0) begin : g_separate_fault
        always @(negedge clk) if(inject) case(bank)
            7: dut.g_lane[0].g_par.u_solver.g_eng[3].m_val0.q=0;
            8: dut.g_lane[0].g_par.u_solver.g_eng[3].m_val1.q=0;
            9: dut.g_lane[0].g_par.u_solver.g_eng[3].m_ptr.q=0;
            default: ;
        endcase
    end else begin : g_packed_fault
        always @(negedge clk) if(inject) case(bank)
            7: dut.g_lane[0].g_par.u_solver.g_eng[3].g_packed.u_tables.g_parity[0].g_slice[0].m_slice.q=0;
            8: dut.g_lane[0].g_par.u_solver.g_eng[3].g_packed.u_tables.g_parity[0].g_slice[1].m_slice.q=0;
            9: dut.g_lane[0].g_par.u_solver.g_eng[3].g_packed.u_tables.g_parity[0].g_slice[2].m_slice.q=0;
            10: dut.g_lane[0].g_par.u_solver.g_eng[3].g_packed.u_tables.g_parity[1].g_slice[0].m_slice.q=0;
            11: dut.g_lane[0].g_par.u_solver.g_eng[3].g_packed.u_tables.g_parity[1].g_slice[1].m_slice.q=0;
            12: dut.g_lane[0].g_par.u_solver.g_eng[3].g_packed.u_tables.g_parity[1].g_slice[2].m_slice.q=0;
            default: ;
        endcase
    end endgenerate
    always @(posedge clk) if(!dut.rst) begin
        if((dut.u_link.bist_pending || dut.u_link.bist_running || dut.u_link.bist_fault)
             && (dut.mid_start || |dut.lane_start))
            $fatal(1,"memory qualification bypassed by mining launch");
        if(dut.mid_start)launches+=1;
    end
    function automatic [7:0] crc8(input [7:0] c,b);
        reg [7:0] v;
        begin
            v=c^b;
            for(integer j=0;j<8;j+=1)v=v[7]?((v<<1)^8'h07):(v<<1);
            crc8=v;
        end
    endfunction
    task automatic byte_out(input [7:0] b);
        begin
            ci=0;repeat(DIV)@(negedge clk);
            for(integer j=0;j<8;j+=1)begin ci=b[j];repeat(DIV)@(negedge clk);end
            ci=1;repeat(DIV)@(negedge clk);
        end
    endtask
    task automatic command(input [7:0] typ,input integer len);
        reg [7:0] c;
        begin
            c=0;byte_out(8'ha5);byte_out(typ);c=crc8(c,typ);
            byte_out(0);c=crc8(c,0);byte_out(8'(len));c=crc8(c,8'(len));
            byte_out(8'(len>>8));c=crc8(c,8'(len>>8));
            for(integer j=0;j<len;j+=1)begin byte_out(8'h31);c=crc8(c,8'h31);end
            byte_out(c);repeat(16)@(negedge clk);
        end
    endtask
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
            9: begin if(rx_byte!=rx_crc)$fatal(1,"PONG CRC mismatch");pongs+=1;end
            default: ;
        endcase
        if(rx_pos>0 && rx_pos<9)rx_crc=crc8(rx_crc,rx_byte);
        rx_pos=rx_pos==9?0:rx_pos+1;
    end
    task automatic ping_expect(input [7:0] status);
        integer next_pong;
        begin
            next_pong=pongs+1;command(8'h04,0);wait(pongs==next_pong);
            if(pong_status!=status)$fatal(1,"PONG fault status got %h expected %h",pong_status,status);
        end
    endtask
    task automatic reset_core;
        begin
            rst_n=0;repeat(12)@(negedge clk);rst_n=1;
            wait(!dut.rst);repeat(12)@(negedge clk);
            if(!dut.u_link.bist_running || bo)$fatal(1,"reset did not acquire BIST ownership");
        end
    endtask
    initial begin
        if(!$value$plusargs("bank=%d",bank))$fatal(1,"bank plusarg required");
        if(bank < -1 || bank > (PACKED_TABLES==0?9:12))$fatal(1,"invalid fault bank");
        inject=bank>=0;reset_core();
        if(bank>=0)command(8'h01,141);
        wait(&dut.lane_bd && !dut.u_link.bist_running);repeat(16)@(negedge clk);
        if(bank>=0)begin
            if(!(|dut.lane_bf) || !dut.u_link.bist_fault)
                $fatal(1,"BIST fault did not reach production link");
            if(launches!=0 || bo)$fatal(1,"failed BIST accepted a queued JOB");
            ping_expect(8'h0e);command(8'h01,141);
            if(launches!=0)$fatal(1,"failed BIST accepted a fresh JOB");
            // Removing a transient RAM read fault must not clear quarantine.
            inject=0;repeat(32)@(negedge clk);
            if(!dut.u_link.bist_fault || launches!=0)$fatal(1,"fault removal bypassed retest");
            command(8'h02,0);command(8'h06,0);
            wait(dut.u_link.bist_running);wait(!(&dut.lane_bd));
            wait(&dut.lane_bd && !dut.u_link.bist_running);
            repeat(16)@(negedge clk);
            if((|dut.lane_bf) || dut.u_link.bist_fault || !bo)$fatal(1,"healthy memory retest did not recover");
        end else if((|dut.lane_bf) || !bo)$fatal(1,"healthy startup test failed");
        ping_expect(8'h04);command(8'h01,141);wait(launches==1);
        command(8'h02,0);reset_core();
        wait(&dut.lane_bd && !dut.u_link.bist_running);repeat(16)@(negedge clk);
        if((|dut.lane_bf) || !bo || launches!=1)$fatal(1,"reset qualification retained stale work");
        $display("core RAM BIST fault PASS: packed=%0d bank=%0d quarantine/retest/reset",PACKED_TABLES,bank);
        $finish;
    end
    initial begin #5000000;$fatal(1,"core RAM BIST fault deadline");end
endmodule
