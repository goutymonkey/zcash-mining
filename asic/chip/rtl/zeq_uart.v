// 8N1 UART used on every chain link (CI/CO down, RI/RO up).
//
// DIV is clocks per bit. Each chip runs from its own oscillator, so the
// receiver re-synchronizes on every start bit and samples mid-bit, which
// tolerates the few-ppm offset between domains easily.
`default_nettype none

module zeq_uart_rx #(
    parameter integer DIV = 16
) (
    input  wire       clk,
    input  wire       rst,
    input  wire       rxd,
    output reg        valid,  // one-cycle pulse with data
    output reg  [7:0] data
);
    localparam integer CW = $clog2(DIV);
    localparam [CW-1:0] FULL = DIV[CW-1:0] - 1'b1;
    localparam [CW-1:0] HALF = DIV[CW:1] - 1'b1;

    reg [2:0]    sync;   // 2FF synchronizer + edge history
    reg [1:0]    st;     // 0 idle, 1 start, 2 data, 3 stop
    reg [CW-1:0] cnt;
    reg [2:0]    bitn;
    wire         rx = sync[1];

    always @(posedge clk) begin
        valid <= 1'b0;
        sync  <= {sync[1:0], rxd};
        if (rst) begin
            st   <= 2'd0;
            sync <= 3'b111;
        end else case (st)
            2'd0: if (!rx) begin cnt <= HALF; st <= 2'd1; end
            2'd1: if (cnt == 0) begin
                if (!rx) begin cnt <= FULL; bitn <= 0; st <= 2'd2; end
                else st <= 2'd0;             // glitch, not a start bit
            end else cnt <= cnt - 1'b1;
            2'd2: if (cnt == 0) begin
                data <= {rx, data[7:1]};     // LSB first
                cnt  <= FULL;
                bitn <= bitn + 1'b1;
                if (bitn == 3'd7) st <= 2'd3;
            end else cnt <= cnt - 1'b1;
            default: if (cnt == 0) begin
                valid <= rx;                 // drop frames with a bad stop bit
                st    <= 2'd0;
            end else cnt <= cnt - 1'b1;
        endcase
    end
endmodule

module zeq_uart_tx #(
    parameter integer DIV = 16
) (
    input  wire       clk,
    input  wire       rst,
    input  wire       valid,
    input  wire [7:0] data,
    output wire       ready,
    output reg        txd
);
    localparam integer CW = $clog2(DIV);
    localparam [CW-1:0] FULL = DIV[CW-1:0] - 1'b1;

    reg [8:0]    sh;     // {data, start}
    reg [3:0]    left;   // start + 8 data + stop, plus one step that ends
                         // the stop bit a full bit time after it began
    reg [CW-1:0] cnt;

    assign ready = (left == 0);

    always @(posedge clk) begin
        if (rst) begin
            txd  <= 1'b1;
            left <= 0;
        end else if (left == 0) begin
            if (valid) begin
                sh   <= {data, 1'b0};
                left <= 4'd11;
                cnt  <= 0;
            end
        end else if (cnt == 0) begin
            txd  <= sh[0];
            sh   <= {1'b1, sh[8:1]};   // shifts in the stop bit
            left <= left - 1'b1;
            cnt  <= FULL;
        end else cnt <= cnt - 1'b1;
    end
endmodule

`default_nettype wire
