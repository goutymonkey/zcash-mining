// Mainnet (200,9) on-die-memory core. Process-independent production RTL.
// PB=4 is the simulation baseline; PB=9 is a scaling candidate, not a
// physically validated configuration. Technology SRAM mapping is required.
`default_nettype none

module zeq200x #(
    parameter integer PB = 4,
    parameter integer SLOTS = 640,
    parameter integer GMAX = 16,
    parameter integer GROUP_REPLAY = 0, // experimental; qualify yield and physical costs
    parameter integer PACKED_TABLES = 0, // candidate pending mainnet qualification
    parameter integer STAGED_NETWORK = 0, // candidate pending transport/yield/PPA qualification
    parameter integer SPLIT_KEYS = 1,
    parameter integer BOOT_BIST = 1,
    parameter integer DIV = 16,
    parameter integer HPB = PB, // hash engines may be fewer than solver engines
    parameter integer HASH_SPLIT = 1, // supported Blake2b steps: 1, 2, 4
    parameter integer BUCKET0_SLOTS = SLOTS, // optional localized capacity candidate
    parameter integer DROP_ZERO = 0, // candidate pending mainnet qualification; makes BUCKET0_SLOTS unnecessary
    parameter integer LEAF_SET = 0, // candidate: linear-time distinct-leaf check
    parameter integer HASH_UNITS = 1, // candidate: Blake2b units per hashing engine
    parameter integer CHAIN = 0 // candidate: write-time key chains instead of the counting sort
) (
    input  wire       clk,
    input  wire       rst_n,
    output wire       rsto_n,
    input  wire [1:0] addr_strap,
    input  wire       ci,
    output wire       co,
    input  wire       ri,
    output wire       ro,
    input  wire       bi,
    output wire       bo,
    input  wire [7:0] tsense,
    output wire       temp_pull
);
    localparam integer N = 200, K = 9, LANES = 1;
    localparam integer CB = N / (K + 1), RW = CB + 2, CW = CB + 3;

    zeq200_core #(.N(N), .K(K), .LANES(LANES), .EXT_MEM(0), .DIV(DIV), .HASH_SPLIT(HASH_SPLIT),
                  .SHARE_FILTER(1), .BOOT_BIST(BOOT_BIST), .ARCH(1), .PAR_BB(12), .PAR_PB(PB), .PAR_SB(10),
                  .PAR_HPB(HPB), .PAR_GMAX(GMAX), .PAR_GROUP_REPLAY(GROUP_REPLAY), .PAR_SLOTS(SLOTS), .PAR_BUCKET0_SLOTS(BUCKET0_SLOTS), .PAR_DROP_ZERO(DROP_ZERO), .PAR_LEAF_SET(LEAF_SET), .PAR_HASH_UNITS(HASH_UNITS), .PAR_CHAIN(CHAIN), .PAR_STAGED_NETWORK(STAGED_NETWORK), .PAR_PACKED_TABLES(PACKED_TABLES), .PAR_SPLIT_KEYS(SPLIT_KEYS), .PAR_COMPACT_VALUES(1)) u_core (
        .clk(clk), .rst_n(rst_n), .rsto_n(rsto_n), .addr_strap(addr_strap),
        .ci(ci), .co(co), .ri(ri), .ro(ro), .bi(bi), .bo(bo),
        .tsense(tsense), .temp_pull(temp_pull),
        .val_req_valid(), .val_req_ready(1'b0), .val_req_we(), .val_req_addr(),
        .val_req_wdata(), .val_rsp_valid(1'b0), .val_rsp_rdata({N{1'b0}}),
        .ptr_req_valid(), .ptr_req_ready(1'b0), .ptr_req_we(), .ptr_req_addr(),
        .ptr_req_wdata(), .ptr_rsp_valid(1'b0), .ptr_rsp_rdata({(2*RW){1'b0}}),
        .ord_req_valid(), .ord_req_ready(1'b0), .ord_req_we(), .ord_req_addr(),
        .ord_req_wdata(), .ord_rsp_valid(1'b0), .ord_rsp_rdata({RW{1'b0}}));
`ifndef SYNTHESIS
    initial begin
        if (HPB < 0 || HPB > PB) $fatal(1, "hash engines must not exceed solver engines");
        if (HASH_SPLIT != 1 && HASH_SPLIT != 2 && HASH_SPLIT != 4)
            $fatal(1, "HASH_SPLIT must be 1, 2 or 4");
    end
`endif
endmodule

`default_nettype wire
