`timescale 1ns/1ps
// Digital UART behavior only. Does not model metastability or pad timing.
module tb_uart_robustness;
    parameter integer DIV=16;
    reg clk=0,rxrst=1,txrst=1,rxd=1,send=0;
    reg [7:0] txdata=0;
    always #5 clk=~clk;
    wire valid,ready,txd;
    wire [7:0] data;
    zeq_uart_rx #(.DIV(DIV)) rx(.clk(clk),.rst(rxrst),.rxd(rxd),.valid(valid),.data(data));
    zeq_uart_tx #(.DIV(DIV)) tx(.clk(clk),.rst(txrst),.valid(send),.data(txdata),.ready(ready),.txd(txd));
    reg [7:0] expected[0:4095];
    reg reset_checks=0;
    integer queued=0,received=0,tx_checked=0,reset_rx=0,reset_tx=0,bad_stops=0,glitches=0;
    always @(posedge clk) if(!rxrst && valid)begin
        if(received>=queued)$fatal(1,"unexpected RX delivery reset=%0d",reset_checks);
        if(data!==expected[received])$fatal(1,"RX byte mismatch index=%0d got=%02x expected=%02x reset=%0d",received,data,expected[received],reset_checks);
        received=received+1;
    end
    task automatic idle_rx;
        begin
            rxd=1;repeat(3*DIV)@(negedge clk);
            if(received!=queued)$fatal(1,"RX missing delivery got=%0d expected=%0d",received,queued);
        end
    endtask
    task automatic raw_byte(input [7:0] b,input real period,input bit good_stop);
        begin
            rxd=0;#(period);
            for(integer i=0;i<8;i=i+1)begin rxd=b[i];#(period);end
            rxd=good_stop;#(period);rxd=1;
        end
    endtask
    task automatic good_byte(input [7:0] b,input real period);
        begin
            expected[queued]=b;queued=queued+1;
            raw_byte(b,period,1);
        end
    endtask
    task automatic check_tx(input [7:0] b);
        reg [7:0] decoded;
        begin
            fork
                begin
                    @(negedge clk);
                    if(!ready)$fatal(1,"TX not ready");
                    txdata=b;send=1;
                    @(negedge clk);send=0;
                end
                begin
                    @(negedge txd);#(15*DIV);
                    for(integer i=0;i<8;i=i+1)begin decoded[i]=txd;#(10*DIV);end
                    if(!txd || decoded!==b)$fatal(1,"TX framing/data mismatch");
                end
            join
            while(!ready)@(negedge clk);
            tx_checked=tx_checked+1;
        end
    endtask
    real period;
    integer before_reset;
    initial begin
        repeat(4)@(negedge clk);rxrst=0;txrst=0;
        // Nine continuous streams: all bytes, three relative rates and phases.
        for(integer rate=-1;rate<=1;rate=rate+1)begin
            period=10.0*DIV*(1.0+rate*0.02);
            for(integer phase=1;phase<=7;phase=phase+3)begin
                idle_rx();@(negedge clk);#(phase);
                for(integer b=0;b<256;b=b+1)good_byte(8'(b),period);
                idle_rx();
            end
        end
        // All data patterns with a low stop bit must be discarded.
        for(integer b=0;b<256;b=b+1)begin
            raw_byte(8'(b),10.0*DIV,0);idle_rx();bad_stops=bad_stops+1;
        end
        // Short pulses cannot become start bits, at multiple clock phases.
        for(integer phase=1;phase<=7;phase=phase+3)begin
            @(negedge clk);#(phase);rxd=0;#10;rxd=1;idle_rx();glitches=glitches+1;
        end
        // Interrupt start/data/stop phases before a full byte can be received.
        reset_checks=1;
        for(integer phase=0;phase<10;phase=phase+1)begin
            before_reset=received;
            rxd=0;#((phase+0.25)*10.0*DIV);
            rxrst=1;rxd=1;repeat(3)@(negedge clk);rxrst=0;idle_rx();
            if(received!=before_reset)$fatal(1,"reset failed to discard RX byte");
            good_byte(8'h96,10.0*DIV);idle_rx();reset_rx=reset_rx+1;
        end
        for(integer b=0;b<256;b=b+1)check_tx(8'(b));
        for(integer phase=0;phase<10;phase=phase+1)begin
            @(negedge clk);txdata=0;send=1;@(negedge clk);send=0;
            #((phase+0.25)*10.0*DIV);txrst=1;
            repeat(3)@(negedge clk);
            if(txd!==1'b1 || ready!==1'b1)$fatal(1,"TX reset did not restore idle");
            txrst=0;check_tx(8'h69);reset_tx=reset_tx+1;
        end
        idle_rx();
        if(queued!=2314 || received!=2314 || tx_checked!=266 || reset_rx!=10 || reset_tx!=10 || bad_stops!=256 || glitches!=3)
            $fatal(1,"incomplete UART coverage");
        $display("uart robustness PASS div=%0d rx=%0d tx=%0d rx_resets=%0d tx_resets=%0d bad_stops=%0d glitches=%0d",DIV,received,tx_checked,reset_rx,reset_tx,bad_stops,glitches);
        $finish;
    end
    initial begin #20000000;$fatal(1,"UART watchdog");end
endmodule
