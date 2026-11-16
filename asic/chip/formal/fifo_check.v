// zeq_fifo: ordering and integrity. An arbitrary pushed byte (tag) must come
// out exactly after the bytes that were ahead of it, with its value intact.
module fifo_check (
    input wire       clk,
    input wire       push,
    input wire [7:0] din,
    input wire       pop,
    input wire       tag
);
    reg init = 1'b1;
    always @(posedge clk) init <= 1'b0;
    wire full, empty;
    wire [7:0] dout;
    wire [2:0] level;
    zeq_fifo #(.AW(2)) dut (.clk(clk), .rst(init), .push(push), .din(din), .full(full),
                            .pop(pop), .empty(empty), .dout(dout), .level(level));
    reg       tagged = 1'b0, done = 1'b0;
    reg [7:0] tdata;
    reg [2:0] ahead;
    wire accept = push && !full;
    always @* begin
        assume (!(pop && empty));          // the link only pops a valid head
        assume (!(tag && tagged));         // tag at most one byte
        if (!init) assert (level <= 3'd5);
    end
    always @(posedge clk) if (!init) begin
        if (accept && tag) begin
            tagged <= 1'b1;
            tdata  <= din;
            ahead  <= level - (pop ? 3'd1 : 3'd0);
        end else if (tagged && !done && pop) begin
            if (ahead == 0) done <= 1'b1;
            else ahead <= ahead - 1'b1;
        end
    end
    always @* if (!init && tagged && !done && pop && ahead == 0) assert (dout == tdata);
endmodule
