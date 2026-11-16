`timescale 1ns/1ps
// Real command UART: damaged frames must not hide subsequent valid commands.
module tb_link_command_recovery;
    parameter integer N=48;
    localparam integer K=N==200?9:5, RW=N/(K+1)+2, DIV=8;
    reg clk=0,rst=1,ci=1;
    reg [1:0] addr=0;
    always #5 clk=~clk;
    wire ro,temp_pull;
    wire [255:0] target;
    zeq_link #(.DIV(DIV),.N(N),.K(K)) dut (
        .clk(clk),.rst(rst),.addr_strap(addr),.ci(ci),.co(),.ri(1'b1),.ro(ro),
        .bi(1'b1),.bo(),.tsense(8'd30),.temp_pull(temp_pull),.hdr_eff(),.mid_start(),
        .mid_done(1'b0),.lane_start(),.lane_abort(),.lane_done(1'b0),
        .lane_nsol(8'd0),.lane_avail(1'b0),.lane_ack(),.sol_raddr(),
        .lane_rdata({RW{1'b0}}),.target_be(target),.bist_start(),.bist_done(1'b0),.bist_fail(1'b0));
    function automatic [7:0] crc8(input [7:0] c,b);
        reg [7:0] v;
        begin
            v=c^b;
            for(integer j=0;j<8;j+=1)v=v[7]?((v<<1)^8'h07):(v<<1);
            crc8=v;
        end
    endfunction
    reg [7:0] capture[0:255],rxbyte;
    integer received=0;
    initial forever begin
        @(negedge ro); #(DIV*15);
        for(integer j=0;j<8;j+=1)begin rxbyte[j]=ro;#(DIV*10);end
        if(!ro)$fatal(1,"bad UART stop bit");
        if(received>=256)$fatal(1,"capture overflow");
        capture[received]=rxbyte;received+=1;
    end
    task automatic byte_out(input [7:0] b,input integer gap);
        begin
            ci=0;repeat(DIV)@(negedge clk);
            for(integer j=0;j<8;j+=1)begin ci=b[j];repeat(DIV)@(negedge clk);end
            ci=1;repeat(DIV+gap)@(negedge clk);
        end
    endtask
    task automatic ping(input integer gap);
        reg [7:0] c;
        begin
            c=0;byte_out(8'ha5,gap);
            byte_out(4,gap);c=crc8(c,4);
            byte_out({6'b0,addr},gap);c=crc8(c,{6'b0,addr});
            byte_out(0,gap);c=crc8(c,0);byte_out(0,gap);c=crc8(c,0);byte_out(c,gap);
        end
    endtask
    reg [255:0] expected_target={256{1'b1}};
    task automatic set_target(input integer crc_mode);
        reg [7:0] c,b;
        reg [255:0] candidate;
        begin
            c=0;candidate=0;byte_out(8'ha5,0);
            byte_out(5,0);c=crc8(c,5);
            byte_out({6'b0,addr},0);c=crc8(c,{6'b0,addr});
            byte_out(32,0);c=crc8(c,32);byte_out(0,0);c=crc8(c,0);
            for(integer j=0;j<32;j+=1)begin
                b=j==0?8'ha5:j==1?8'h5a:8'(j*7);
                candidate={candidate[247:0],b};
                byte_out(b,0);c=crc8(c,b);
            end
            if(crc_mode!=0)byte_out(crc_mode==1?c:(c^8'h01),0);
            if(crc_mode==1)expected_target=candidate;
        end
    endtask
    task automatic wrong_length(input [7:0] typ,input integer length);
        reg [7:0] c,b;
        begin
            c=0;byte_out(8'ha5,0);
            byte_out(typ,0);c=crc8(c,typ);
            byte_out({6'b0,addr},0);c=crc8(c,{6'b0,addr});
            byte_out(8'(length),0);c=crc8(c,8'(length));byte_out(0,0);c=crc8(c,0);
            for(integer j=0;j<length;j+=1)begin
                b=j==0?8'd1:8'd0;byte_out(b,0);c=crc8(c,b);
            end
            byte_out(c,0);repeat(12000)@(negedge clk);
        end
    endtask
    function automatic integer pongs;
        integer count;
        reg [7:0] c;
        begin
            count=0;
            for(integer i=0;i+9<received;i+=1)begin
                c=0;for(integer j=1;j<9;j+=1)c=crc8(c,capture[i+j]);
                if(capture[i]==8'h5a && capture[i+1]==8'h84 && capture[i+2]=={6'b0,addr} &&
                   capture[i+3]==4 && capture[i+4]==0 && capture[i+5]==2 &&
                   capture[i+6]==0 && capture[i+7]==30 && capture[i+8]==1 && capture[i+9]==c)count+=1;
            end
            pongs=count;
        end
    endfunction
    integer scenario=0,strap=0;
    initial begin
        if(!$value$plusargs("CASE=%d",scenario))scenario=0;
        if(!$value$plusargs("ADDR=%d",strap))strap=0;
        addr=2'(strap);
        repeat(8)@(negedge clk);rst=0;repeat(8)@(negedge clk);
        case(scenario)
            0:begin // oversized length: next valid command follows promptly
                byte_out(8'ha5,0);byte_out(5,0);byte_out({6'b0,addr},0);
                byte_out(8'hff,0);byte_out(8'hff,0);
            end
            1:begin // truncated header
                byte_out(8'ha5,0);byte_out(5,0);byte_out({6'b0,addr},0);
                repeat(12000)@(negedge clk);
            end
            2:begin // truncated SET_TARGET must not commit its partial value
                byte_out(8'ha5,0);byte_out(5,0);byte_out({6'b0,addr},0);
                byte_out(32,0);byte_out(0,0);byte_out(8'h12,0);
                repeat(12000)@(negedge clk);
            end
            3:begin // valid slow command; allow its response to drain
                ping(4*(10*DIV+8));repeat(12000)@(negedge clk);
            end
            4:set_target(1); // SOF-like payload bytes remain data
            5:begin // timeout while waiting for command type
                byte_out(8'ha5,0);repeat(12000)@(negedge clk);
            end
            6:begin // fully staged target but no CRC must never commit
                set_target(0);repeat(12000)@(negedge clk);
            end
            7:begin // valid CRC cannot authorize an invalid PING length
                wrong_length(4,1);
                if(received!=0)$fatal(1,"invalid command committed");
            end
            8:wrong_length(5,31); // short target must leave active value intact
            9:begin // received-byte interval four clocks below timeout
                ping(32*(10*DIV+8)-10*DIV-4);repeat(12000)@(negedge clk);
            end
            10:begin // interval four clocks above timeout must abandon command
                ping(32*(10*DIV+8)-10*DIV+4);repeat(12000)@(negedge clk);
                if(received!=0)$fatal(1,"over-timeout command accepted");
            end
            11:begin // bad CRC must not commit a completely staged target
                set_target(2);repeat(12000)@(negedge clk);
            end
            12:begin // invalid thermal command length must not lower threshold
                wrong_length(3,2);
                if(temp_pull)$fatal(1,"invalid command committed");
            end
            default:$fatal(1,"unknown case");
        endcase
        ping(0);repeat(12000)@(negedge clk);
        if(pongs()!=((scenario==3 || scenario==9)?2:1))$fatal(1,"local PONG starved after downstream case=%0d addr=%0d",scenario,strap);
        if(target!==expected_target)$fatal(1,"command staging/target corruption");
        set_target(1);ping(0);repeat(12000)@(negedge clk);
        if(pongs()!=((scenario==3 || scenario==9)?3:2) || target!==expected_target)$fatal(1,"valid command did not recover");
        $display("link recovery PASS case=%0d addr=%0d received=%0d",scenario,strap,received);$finish;
    end
    initial begin #50000000;$fatal(1,"test watchdog");end
endmodule
