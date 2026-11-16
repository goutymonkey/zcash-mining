// UART loopback: a byte sent by zeq_uart_tx is received by zeq_uart_rx
// unchanged, for every byte value (bounded proof, formal/uart.ys).
module uart_loop (
    input wire       clk,
    input wire       rst,
    input wire [7:0] b          // any byte
);
    reg        init = 1'b1;
    reg        sent = 1'b0;
    reg  [7:0] held;
    wire       ready, txd, valid;
    wire [7:0] data;
    zeq_uart_tx #(.DIV(4)) tx (.clk(clk), .rst(init), .valid(!sent && !init),
                                .data(b), .ready(ready), .txd(txd));
    zeq_uart_rx #(.DIV(4)) rx (.clk(clk), .rst(init), .rxd(txd), .valid(valid), .data(data));
    reg [7:0] t = 0;
    always @(posedge clk) begin
        init <= 1'b0;
        if (!init && !sent) begin sent <= 1'b1; held <= b; end
        if (!init && t != 8'hFF) t <= t + 1'b1;
    end
    always @* begin
        if (valid) assert (sent && data == held);   // correct byte, never spurious
        if (t == 8'd60) assert (got);                // and it arrives in time
    end
    reg got = 1'b0;
    always @(posedge clk) if (valid) got <= 1'b1;
endmodule
