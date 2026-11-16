`timescale 1ns/1ps
// Actual UART framing and forwarding recovery; no internal force/cut points.
module tb_link_recovery;
    parameter integer N=48;
    localparam integer K=N==200?9:5;
    localparam integer RW=N/(K+1)+2;
    localparam integer DIV=8;
    reg clk=0,rst=1,ci=1,ri=1;
    reg [1:0] addr=0;
    always #5 clk=~clk;
    wire ro;
    zeq_link #(.DIV(DIV),.N(N),.K(K)) dut (
        .clk(clk),.rst(rst),.addr_strap(addr),.ci(ci),.co(),.ri(ri),.ro(ro),
        .bi(1'b1),.bo(),.tsense(8'd30),.temp_pull(),.hdr_eff(),.mid_start(),
        .mid_done(1'b0),.lane_start(),.lane_abort(),.lane_done(1'b0),
        .lane_nsol(8'd0),.lane_avail(1'b0),.lane_ack(),.sol_raddr(),
        .lane_rdata({RW{1'b0}}),.target_be(),.bist_start(),.bist_done(1'b0),.bist_fail(1'b0));
    function automatic [7:0] crc8(input [7:0] c,b);
        reg [7:0] v;
        begin
            v=c^b;
            for(integer j=0;j<8;j+=1)v=v[7]?((v<<1)^8'h07):(v<<1);
            crc8=v;
        end
    endfunction
    reg [7:0] capture[0:4095],rxbyte;
    reg [7:0] expected_prefix[0:4095];
    integer prefix_count=0;
    integer received=0;
    initial forever begin
        @(negedge ro); #(DIV*15);
        for(integer j=0;j<8;j+=1)begin rxbyte[j]=ro;#(DIV*10);end
        if(!ro)$fatal(1,"bad UART stop bit");
        if(received>=4096)$fatal(1,"capture overflow");
        capture[received]=rxbyte;received+=1;
    end
    task automatic byte_out(input bit upstream,input [7:0] b,input integer gap);
        begin
            if(upstream)ri=0;else ci=0;
            repeat(DIV)@(negedge clk);
            for(integer j=0;j<8;j+=1)begin
                if(upstream)ri=b[j];else ci=b[j];
                repeat(DIV)@(negedge clk);
            end
            if(upstream)ri=1;else ci=1;
            repeat(DIV+gap)@(negedge clk);
        end
    endtask
    task automatic maximum_solution;
        reg [7:0] c,b;
        integer length,total;
        begin
            length=4*(1<<K)+4;total=length+6;c=0;
            for(integer j=0;j<total;j+=1)begin
                case(j)
                    0:b=8'h5a;1:b=8'h81;2:b=3;
                    3:b=8'(length);4:b=8'(length>>8);
                    default:b=j==total-1?c:8'(j);
                endcase
                if(j>0 && j<total-1)c=crc8(c,b);
                expected_prefix[j]=b;
                byte_out(1,b,0);
            end
            prefix_count=total;
        end
    endtask
    task automatic ping;
        reg [7:0] c;
        begin
            c=0;byte_out(0,8'ha5,0);
            byte_out(0,8'h04,0);c=crc8(c,8'h04);
            byte_out(0,{6'b0,addr},0);c=crc8(c,{6'b0,addr});
            byte_out(0,0,0);c=crc8(c,0);
            byte_out(0,0,0);c=crc8(c,0);byte_out(0,c,0);
        end
    endtask
    task automatic forwarded_pong(input integer gap);
        reg [7:0] c,b;
        begin
            c=0;byte_out(1,8'h5a,gap);
            for(integer j=1;j<9;j+=1)begin
                case(j)
                    1:b=8'h84;2:b=8'h03;3:b=4;4:b=0;
                    5:b=2;6:b=0;7:b=31;default:b=1;
                endcase
                byte_out(1,b,gap);c=crc8(c,b);
            end
            byte_out(1,c,gap);
        end
    endtask
    function automatic integer pongs(input [7:0] id,sensor);
        integer count;
        reg [7:0] c;
        begin
            count=0;
            for(integer i=0;i+9<received;i+=1)begin
                c=0;
                for(integer j=1;j<9;j+=1)c=crc8(c,capture[i+j]);
                if(capture[i]==8'h5a && capture[i+1]==8'h84 && capture[i+2]==id &&
                   capture[i+3]==4 && capture[i+4]==0 && capture[i+5]==2 &&
                   capture[i+6]==0 && capture[i+7]==sensor && capture[i+8]==1 && capture[i+9]==c)
                    count+=1;
            end
            pongs=count;
        end
    endfunction
    integer scenario=0,strap=0,byte_budget;
    initial begin
        if(!$value$plusargs("CASE=%d",scenario))scenario=0;
        if(!$value$plusargs("ADDR=%d",strap))strap=0;
        addr=2'(strap);
        case(strap)
            0:byte_budget=10*DIV+8;
            1:byte_budget=(4*(10*DIV+8)+2)/3;
            2:byte_budget=2*(10*DIV+8);
            default:byte_budget=4*(10*DIV+8);
        endcase
        repeat(8)@(negedge clk);rst=0;repeat(8)@(negedge clk);
        case(scenario)
            0: begin // malformed length, including 16-bit end-index wrap
                byte_out(1,8'h5a,0);byte_out(1,8'h84,0);byte_out(1,3,0);
                byte_out(1,8'hff,0);byte_out(1,8'hff,0);byte_out(1,0,0);
            end
            1: begin // downstream chip disappears partway through a header
                byte_out(1,8'h5a,0);byte_out(1,8'h84,0);byte_out(1,3,0);
            end
            2: begin // legal header but missing payload/CRC
                byte_out(1,8'h5a,0);byte_out(1,8'h84,0);byte_out(1,3,0);
                byte_out(1,4,0);byte_out(1,0,0);byte_out(1,2,0);
            end
            3: forwarded_pong(4*(10*DIV+8)); // slower than the tail's pacing
            4: maximum_solution(); // includes SOF-like payload bytes
            default:$fatal(1,"unknown case");
        endcase
        ping();
        if(scenario==4)repeat(prefix_count*(4*(10*DIV+8)+8)+12000)@(negedge clk);
        // Invalid lengths must release ownership promptly, without relying
        // on the longer truncated-frame watchdog to rescue the packet.
        else if(scenario==0)repeat(12*(byte_budget+8)+256)@(negedge clk);
        else repeat(12000)@(negedge clk);
        if(pongs({6'b0,addr},30)!=1)$fatal(1,"local PONG starved after upstream case=%0d addr=%0d",scenario,strap);
        for(integer j=0;j<prefix_count;j+=1)
            if(capture[j]!==expected_prefix[j])$fatal(1,"maximum solution corrupted at byte %0d",j);
        forwarded_pong(0);repeat(12000)@(negedge clk);
        if(pongs(3,31)!=(scenario==3?2:1))$fatal(1,"valid forwarding did not recover");
        $display("link recovery PASS case=%0d addr=%0d received=%0d",scenario,strap,received);
        $finish;
    end
    initial begin #50000000;$fatal(1,"test watchdog");end
endmodule
