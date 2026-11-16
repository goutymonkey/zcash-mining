// Pointwise sequential equivalence: an arbitrary fixed row represents every
// row in the bank. Equal corresponding initial states, arbitrary input trace.
module watched #(parameter AW=8,DW=11,MUTANT=0)(input clk,rst,clear,par,we,input[AW-1:0]wa,input[DW-1:0]data);
localparam BPE=1<<AW;
(* anyconst *) reg [AW:0] watch;
reg [DW-1:0] old_value,new_value;
reg initialized=0;
integer ci;
always @(posedge clk) begin
 initialized<=1;
 if(!initialized) assume(old_value==new_value);
 assert(old_value==new_value);
 if(rst || clear) begin
  for(ci=0;ci<BPE;ci=ci+1)
   if(watch=={par,ci[AW-1:0]}) old_value<=0;
 end else if(we && watch=={par,wa}) old_value<=data;
 if(rst || clear) begin
  for(ci=0;ci<2*BPE;ci=ci+1)
   if((MUTANT ? par!=ci[AW] : par==ci[AW]) && watch==ci) new_value<=0;
 end else if(we && watch=={par,wa}) new_value<=data;
end
endmodule
