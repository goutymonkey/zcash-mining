// Arbitrary decoded bytes drive the actual command parser. UART sampling,
// staged JOB/target byte order, solver behavior and analog effects are outside
// this proof. No command strobes or parser state are assumed correct.
module link_parser_formal #(
    parameter integer N=48,K=5
) (input wire clk,rst,d_valid,input wire [7:0] d_byte);
    (* anyconst *) reg [1:0] address;
    wire [2:0] pst;
    wire [7:0] ptyp,padr,pcrc,ot_thresh,ot_stage;
    wire [15:0] plen,pcnt;
    wire [255:0] target_be,tgt_stage;
    wire cmd_job,cmd_stop,cmd_ping,cmd_bist,command_timeout;
    link_parser dut(
        .clk(clk),.rst(rst),.addr_strap(address),.ci(1'b1),.co(),
        .ri(1'b1),.ro(),.bi(1'b1),.bo(),.tsense(8'd30),.temp_pull(),
        .hdr_eff(),.mid_start(),.mid_done(1'b0),.lane_start(),.lane_abort(),
        .lane_done(1'b0),.lane_nsol(8'd0),.lane_avail(1'b0),.lane_ack(),
        .sol_raddr(),.lane_rdata({(N/(K+1)+2){1'b0}}),.target_be(target_be),
        .bist_start(),.bist_done(1'b0),.bist_fail(1'b0),
        .d_valid(d_valid),.d_byte(d_byte),.pst(pst),.ptyp(ptyp),.padr(padr),
        .pcrc(pcrc),.plen(plen),.pcnt(pcnt),.ot_thresh(ot_thresh),
        .ot_stage(ot_stage),.tgt_stage(tgt_stage),.command_timeout(command_timeout),
        .cmd_job(cmd_job),.cmd_stop(cmd_stop),.cmd_ping(cmd_ping),.cmd_bist(cmd_bist));
    // Serial polynomial recurrence, distinct from the DUT's byte-XOR loop.
    function [7:0] crc_step(input [7:0] previous,octet);
        reg [7:0] state;
        reg feedback;
        integer bit_index;
        begin
            state=previous;
            for(bit_index=7;bit_index>=0;bit_index=bit_index-1)begin
                feedback=state[7]^octet[bit_index];
                state={state[6:0],1'b0};
                if(feedback)state=state^8'h07;
            end
            crc_step=state;
        end
    endfunction
    function legal_length(input [7:0] typ,input [15:0] length);
        begin
            case(typ)
                1:legal_length=length==141;
                2,4,6:legal_length=length==0;
                3:legal_length=length==1;
                5:legal_length=length==32;
                default:legal_length=0;
            endcase
        end
    endfunction
    reg past_valid=0;
    reg [7:0] reference_crc;
    wire commit_ok=!rst && d_valid && pst==6 && d_byte==reference_crc &&
                   (padr=={6'b0,address} || padr==8'hff) && legal_length(ptyp,plen);
    always @(posedge clk)begin
        past_valid<=1;
        if(!past_valid)assume(rst);
        if(rst || (d_valid && pst==0 && d_byte==8'ha5))reference_crc<=0;
        else if(d_valid && pst>=1 && pst<=5)reference_crc<=crc_step(reference_crc,d_byte);
        if(past_valid)begin
            assert(pst<=6);
            if($past(!rst && d_valid && pst==1))assert(ptyp==$past(d_byte));
            else assert(ptyp==$past(ptyp));
            if($past(!rst && d_valid && pst==2))assert(padr==$past(d_byte));
            else assert(padr==$past(padr));
            if($past(!rst && d_valid && pst==3))assert(plen[7:0]==$past(d_byte));
            else assert(plen[7:0]==$past(plen[7:0]));
            if($past(!rst && d_valid && pst==4))assert(plen[15:8]==$past(d_byte));
            else assert(plen[15:8]==$past(plen[15:8]));
            if(pst!=0)assert(pcrc==reference_crc);
            if(pst==5 || pst==6)assert(legal_length(ptyp,plen));
            if(pst==5)assert(plen>0 && pcnt<plen);
            if(pst==6)assert(pcnt==plen);
            assert(cmd_job==$past(commit_ok && ptyp==1));
            assert(cmd_stop==$past(commit_ok && ptyp==2));
            assert(cmd_ping==$past(commit_ok && ptyp==4));
            assert(cmd_bist==$past(commit_ok && ptyp==6));
            if($past(rst))begin
                assert(pst==0);
                assert(target_be=={256{1'b1}} && ot_thresh==200);
            end else begin
                // Check the protocol transitions as well as commit guards,
                // so stale metadata cannot legitimize a skipped header.
                if($past(command_timeout))assert(pst==0);
                else if(!$past(d_valid))assert(pst==$past(pst));
                else case($past(pst))
                    0:assert(pst==($past(d_byte)==8'ha5 ? 1 : 0));
                    1:begin assert(pst==2);assert(ptyp==$past(d_byte));end
                    2:begin assert(pst==3);assert(padr==$past(d_byte));end
                    3:begin assert(pst==4);assert(plen[7:0]==$past(d_byte));end
                    4:begin
                        assert(plen[15:8]==$past(d_byte));assert(pcnt==0);
                        if(!$past(legal_length(ptyp,{d_byte,plen[7:0]})))assert(pst==0);
                        else assert(pst==($past({d_byte,plen[7:0]})==0 ? 6 : 5));
                    end
                    5:begin
                        assert(pcnt==$past(pcnt)+16'd1);
                        assert(pst==($past(pcnt)==$past(plen)-16'd1 ? 6 : 5));
                    end
                    6:assert(pst==0);
                endcase
                if($past(commit_ok && ptyp==5))assert(target_be==$past(tgt_stage));
                else assert(target_be==$past(target_be));
                if($past(commit_ok && ptyp==3))assert(ot_thresh==$past(ot_stage));
                else assert(ot_thresh==$past(ot_thresh));
                if($past(command_timeout))assert(pst==0);
                if($past(pst==6 && d_valid))assert(pst==0);
            end
        end
    end
endmodule
