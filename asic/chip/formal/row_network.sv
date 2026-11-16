// Mark one arbitrary accepted transaction. Marker bits do not affect routing.
// With arbitrary other traffic, it must arrive once, intact, at its bank within
// G cycles, unless reset/cancel explicitly discards it. All banks always accept.
module row_network_formal #(parameter integer PB=2,DW=32,CHECK_PROGRESS=1)(
    input wire clk,rst,cancel,choose,
    input wire [(1<<PB)-1:0] requests,
    input wire [(1<<PB)*PB-1:0] targets,
    input wire [(1<<PB)*(DW-1)-1:0] payloads
);
    localparam integer P=1<<PB,SB=PB/2,GB=PB-SB,G=1<<GB;
    (* anyconst *) reg [PB-1:0] watched_source;
    reg initial_cycle=1;
    always @(posedge clk) initial_cycle<=0;
    always @* if(initial_cycle) assume(rst);
    reg issued,pending;
    reg [DW-2:0] expected;
    reg [PB-1:0] destination;
    reg [PB+1:0] age;
    wire [P*DW-1:0] input_data,output_data;
    wire [P-1:0] accepted,output_valid;
    wire idle;
`ifdef NETWORK_PROOF
    wire [G*G-1:0] proof_valid;
    wire [G*G*DW-1:0] proof_data;
    wire [G*G*SB-1:0] proof_target;
`endif
    wire mark=choose && !issued;
    genvar s;
    generate for(s=0;s<P;s=s+1) begin : g_payload
        assign input_data[s*DW +: DW]={mark && watched_source==s[PB-1:0],payloads[s*(DW-1) +: DW-1]};
    end endgenerate
    zeq_row_network #(.PB(PB),.DW(DW)) dut (
        .clk(clk),.rst(rst),.cancel(cancel),.in_valid(requests),.in_target(targets),.in_data(input_data),
        .in_take(accepted),.out_valid(output_valid),.out_data(output_data),.idle(idle)
`ifdef NETWORK_PROOF
        ,.proof_valid(proof_valid),.proof_data(proof_data),.proof_target(proof_target)
`endif
    );
    integer bank,count;
    always @* begin
        count=0;
        for(bank=0;bank<P;bank=bank+1) if(output_valid[bank] && output_data[bank*DW+DW-1]) begin
            count=count+1;
            assert(pending);
            assert(destination==bank[PB-1:0]);
            assert(output_data[bank*DW +: DW-1]==expected);
        end
        assert(count<=1);
        assert((accepted & ~requests)==0);
        if(rst || cancel) assert(accepted==0 && output_valid==0 && idle);
        if(CHECK_PROGRESS!=0 && !rst && !cancel && pending) assert(age<G+1);
    end
`ifdef NETWORK_PROOF
    // Inductive storage invariant: a pending marker occupies exactly one
    // link, with the captured data and destination. These are assertions,
    // not assumptions that constrain away a lost/corrupted packet.
    integer link,buffered;
    always @* begin
        buffered=0;
        for(link=0;link<G*G;link=link+1) if(proof_valid[link] && proof_data[link*DW+DW-1]) begin
            buffered=buffered+1;
            assert(pending);
            assert(proof_data[link*DW +: DW-1]==expected);
            assert(destination=={GB'(link%G),proof_target[link*SB +: SB]});
        end
        assert(buffered<=1);
        if(!rst && !cancel) begin
            assert(pending==(buffered==1));
            assert(!pending || issued);
        end
    end
`endif
    always @(posedge clk) begin
        if(rst || cancel) begin issued<=0;pending<=0;age<=0;end
        else begin
            if(mark && accepted[watched_source]) begin
                issued<=1;pending<=1;age<=0;
                destination<=targets[watched_source*PB +: PB];
                expected<=payloads[watched_source*(DW-1) +: DW-1];
            end
            if(pending) age<=age+1'b1;
            if(count!=0) pending<=0;
        end
    end
endmodule
