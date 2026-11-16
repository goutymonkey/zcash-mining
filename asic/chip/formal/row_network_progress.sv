// Control proof: arbitrary accepted row is delivered within G cycles unless
// reset/cancel flushes it. Data is a marker only; full payload integrity is
// checked separately by row_network.sv. No fairness assumption on other input
// traffic is needed because every destination consumes one grant per cycle.
module row_network_progress #(parameter integer PB=4)(
    input wire clk,rst,cancel,choose,
    input wire [(1<<PB)-1:0] requests,
    input wire [(1<<PB)*PB-1:0] targets
);
    localparam integer P=1<<PB,SB=PB/2,GB=PB-SB,G=1<<GB;
    (* anyconst *) reg [PB-1:0] watched_source;
    reg initial_cycle=1;
    always @(posedge clk) initial_cycle<=0;
    always @* if(initial_cycle) assume(rst);
    reg issued,pending;
    reg [PB-1:0] destination;
    reg [GB:0] age;
    wire [P-1:0] accepted,output_valid;
    wire [P*2-1:0] input_data,output_data;
    wire [G*G-1:0] valid;
    wire [G*G*2-1:0] data;
    wire [G*G*SB-1:0] target;
    wire [P*GB-1:0] rr;
    wire idle;
    wire mark=choose && !issued;
    genvar s;
    generate for(s=0;s<P;s=s+1) begin : g_input
        assign input_data[s*2 +: 2]={mark && watched_source==PB'(s),1'b0};
    end endgenerate
    zeq_row_network #(.PB(PB),.DW(2)) dut (
        .clk(clk),.rst(rst),.cancel(cancel),.in_valid(requests),.in_target(targets),.in_data(input_data),
        .in_take(accepted),.out_valid(output_valid),.out_data(output_data),.idle(idle),
        .proof_valid(valid),.proof_data(data),.proof_target(target),.proof_rr(rr)
    );
    wire [GB-1:0] source_group=watched_source[PB-1:SB];
    // Modulo subtraction is distance from the next RR candidate to this row.
    wire [GB-1:0] distance=source_group-rr[destination*GB +: GB];
    integer link,bank,buffered,delivered;
    always @* begin
        buffered=0;
        delivered=0;
        for(link=0;link<G*G;link=link+1) if(valid[link] && data[link*2+1]) begin
            buffered=buffered+1;
            assert(pending);
            assert(source_group==GB'(link/G));
            assert(destination=={GB'(link%G),target[link*SB +: SB]});
        end
        for(bank=0;bank<P;bank=bank+1) if(output_valid[bank] && output_data[bank*2+1]) begin
            delivered=delivered+1;
            assert(pending && destination==PB'(bank));
        end
        assert(buffered<=1 && delivered<=1);
        if(!rst && !cancel) begin
            assert(pending==(buffered==1));
            assert(!pending || issued);
            if(pending) begin
                assert(age<G);
                // Every intervening grant moves RR toward the waiting row.
                // Prove this ranking invariant, rather than assume progress.
                assert(32'(age)+32'(distance)<G);
            end
        end
    end
    always @(posedge clk) begin
        if(rst || cancel) begin issued<=0;pending<=0;age<=0;end
        else begin
            if(mark && accepted[watched_source]) begin
                issued<=1;pending<=1;age<=0;
                destination<=targets[watched_source*PB +: PB];
            end
            if(pending) age<=age+1'b1;
            if(delivered!=0) pending<=0;
        end
    end
endmodule
