/*
 * bp_fe_pc_gen.v
 *
 * pc_gen.v provides the interfaces for the pc_gen logics and also interfacing
 * other modules in the frontend. PC_gen provides the pc for the itlb and icache.
 * PC_gen also provides the BTB, BHT and RAS indexes for the backend (the queue
 * between the frontend and the backend, i.e. the frontend queue).
*/

module bp_fe_pc_gen
 import bp_common_pkg::*;
 import bp_fe_pkg::*;
 #(parameter vaddr_width_p="inv"
   , parameter paddr_width_p="inv"
   , parameter eaddr_width_p="inv"
   , parameter btb_indx_width_p="inv"
   , parameter bht_indx_width_p="inv"
   , parameter ras_addr_width_p="inv"
   , parameter instr_width_p="inv"
   , parameter asid_width_p="inv"
   , parameter bp_first_pc_p="inv"
   , localparam instr_scan_width_lp=`bp_fe_instr_scan_width
   , localparam branch_metadata_fwd_width_lp=btb_indx_width_p+bht_indx_width_p+ras_addr_width_p
   , localparam bp_fe_pc_gen_icache_width_lp=eaddr_width_p
   , localparam bp_fe_icache_pc_gen_width_lp=`bp_fe_icache_pc_gen_width(eaddr_width_p)
   , localparam bp_fe_pc_gen_itlb_width_lp=`bp_fe_pc_gen_itlb_width(eaddr_width_p)
   , localparam bp_fe_pc_gen_width_i_lp=`bp_fe_pc_gen_cmd_width(vaddr_width_p,branch_metadata_fwd_width_lp)
   , localparam bp_fe_pc_gen_width_o_lp=`bp_fe_pc_gen_queue_width(vaddr_width_p,branch_metadata_fwd_width_lp)
   , parameter prediction_on_p=1
   , parameter branch_predictor_p="inv"
   )
  (input                                             clk_i
   , input                                           reset_i
   , input                                           v_i
    
   , output logic [bp_fe_pc_gen_icache_width_lp-1:0] pc_gen_icache_o
   , output logic                                    pc_gen_icache_v_o
   , input                                           pc_gen_icache_ready_i

   , input [bp_fe_icache_pc_gen_width_lp-1:0]        icache_pc_gen_i
   , input                                           icache_pc_gen_v_i
   , output logic                                    icache_pc_gen_ready_o
   , input                                           icache_miss_i

   , output logic [bp_fe_pc_gen_itlb_width_lp-1:0]   pc_gen_itlb_o
   , output logic                                    pc_gen_itlb_v_o
   , input                                           pc_gen_itlb_ready_i
     
   , output logic [bp_fe_pc_gen_width_o_lp-1:0]      pc_gen_fe_o
   , output logic                                    pc_gen_fe_v_o
   , input                                           pc_gen_fe_ready_i

   , input [bp_fe_pc_gen_width_i_lp-1:0]             fe_pc_gen_i
   , input                                           fe_pc_gen_v_i
   , output logic                                    fe_pc_gen_ready_o
   );


   
//the first level of structs
`declare_bp_fe_structs(vaddr_width_p,paddr_width_p,asid_width_p,branch_metadata_fwd_width_lp)
//fe to pc_gen
`declare_bp_fe_pc_gen_cmd_s(branch_metadata_fwd_width_lp);
//pc_gen to icache
`declare_bp_fe_pc_gen_icache_s(eaddr_width_p);
//pc_gen to itlb
`declare_bp_fe_pc_gen_itlb_s(eaddr_width_p);
//icache to pc_gen
`declare_bp_fe_icache_pc_gen_s(eaddr_width_p);
//the second level structs definitions
`declare_bp_fe_branch_metadata_fwd_s(btb_indx_width_p,bht_indx_width_p,ras_addr_width_p);

   
//the first level structs instatiations
bp_fe_pc_gen_queue_s        pc_gen_queue;
bp_fe_pc_gen_cmd_s          fe_pc_gen_cmd;
bp_fe_pc_gen_icache_s       pc_gen_icache;
bp_fe_pc_gen_itlb_s         pc_gen_itlb;
bp_fe_branch_metadata_fwd_s branch_metadata_fwd_i;
bp_fe_branch_metadata_fwd_s branch_metadata_fwd_o;
bp_fe_icache_pc_gen_s       icache_pc_gen;


   
//the second level structs instatiations
bp_fe_fetch_s            pc_gen_fetch;
bp_fe_exception_s        pc_gen_exception;
bp_fe_instr_scan_s       scan_instr;
   
   
// pipeline pc's
logic [eaddr_width_p-1:0]       pc_f2;
logic                           pc_v_f2;
logic [eaddr_width_p-1:0]       pc_f1;
// pc_v_f1 is not a pipeline register, because the squash needs to be 
// done in the same cycle as when we know the instruction in f2 is
// a branch
logic                           pc_v_f1;
logic [eaddr_width_p-1:0]       pc_n;

logic                           stall;

//branch prediction wires
logic                           is_br;
logic                           is_jal;
logic [eaddr_width_p-1:0]       br_target;
logic                           is_back_br;
logic                           predict_taken;

// icache miss recovery wires
logic                           icache_miss_recover;
logic                           icache_miss_prev;


logic [eaddr_width_p-1:0]       btb_target;
logic [instr_width_p-1:0]       next_instr;
logic [instr_width_p-1:0]       instr;
logic [instr_width_p-1:0]       last_instr;
logic [instr_width_p-1:0]       instr_out;

//control signals
logic                          misalignment;
logic                          predict;
logic                          pc_redirect_after_icache_miss;
logic                          stalled_pc_redirect;
logic                          bht_r_v_branch_jalr_inst;
logic                          branch_inst;
   
//connect pc_gen to the rest of the FE submodules as well as FE top module   
assign pc_gen_icache_o = pc_gen_icache;
assign pc_gen_itlb_o   = pc_gen_itlb;
assign pc_gen_fe_o     = pc_gen_queue;
assign fe_pc_gen_cmd   = fe_pc_gen_i;
assign icache_pc_gen   = icache_pc_gen_i;

assign misalignment          = fe_pc_gen_v_i
                               && fe_pc_gen_cmd.pc_redirect_valid 
                               && ~fe_pc_gen_cmd.pc[3:0] == 4'h0 
                               && ~fe_pc_gen_cmd.pc[3:0] == 4'h4
                               && ~fe_pc_gen_cmd.pc[3:0] == 4'h8
                               && ~fe_pc_gen_cmd.pc[3:0] == 4'hC;
   
/* output wiring */
// there should be fixes to the pc signal sent out according to the valid/ready signal pairs
always_comb 
  begin
    pc_gen_queue.msg_type            = (misalignment) ?  e_fe_exception : e_fe_fetch;
    pc_gen_exception.exception_code  = (misalignment) ? e_instr_addr_misaligned : e_illegal_instruction;
    pc_gen_fetch.pc                  = icache_pc_gen.addr;
    pc_gen_fetch.instr               = icache_pc_gen.instr;
    pc_gen_fetch.branch_metadata_fwd = branch_metadata_fwd_o;
    pc_gen_fetch.padding             = '0;
    pc_gen_exception.padding         = '0;
    pc_gen_queue.msg                 = (pc_gen_queue.msg_type == e_fe_fetch) ? pc_gen_fetch : pc_gen_exception;
    pc_gen_icache.virt_addr          = pc_n;
    pc_gen_itlb.virt_addr            = pc_n;
  end
   
//valid-ready signals assignments
always_comb 
begin
  if (reset_i) 
    begin
      pc_gen_fe_v_o     = 1'b0;
      fe_pc_gen_ready_o = 1'b0;
      pc_gen_icache_v_o = 1'b0;
    end 
  else 
    begin
      fe_pc_gen_ready_o = ~stall & fe_pc_gen_v_i;
      pc_gen_fe_v_o     = pc_gen_fe_ready_i & icache_pc_gen_v_i & ~icache_miss_i & pc_v_f2;
      pc_gen_icache_v_o = pc_gen_fe_ready_i && ~icache_miss_i;
    end
end

assign pc_v_f1 = ~predict_taken;

// stall logic
assign stall = ~pc_gen_fe_ready_i | ~pc_gen_icache_ready_i | icache_miss_i;

assign icache_miss_recover = icache_miss_prev & (~icache_miss_i);
// imiss recover logic
always_ff @(posedge clk_i)
begin
    if (reset_i)
    begin
        icache_miss_prev <= '0;
    end
    else
    begin
        icache_miss_prev <= icache_miss_i;
    end
end

always_comb
begin
    // if we need to redirect
    if (fe_pc_gen_cmd.pc_redirect_valid && fe_pc_gen_v_i) begin
        pc_n = fe_pc_gen_cmd.pc;
    end
    // if we've missed in the icache
    else if (icache_miss_recover)
    begin
        pc_n = pc_f2;
    end
    else if (predict_taken)
    begin
        pc_n = br_target;
    end
    else
    begin
        pc_n = pc_f1 + 4;
    end
end

always_ff @(posedge clk_i)
begin
    if (reset_i) 
    begin
        pc_f2 <= '0;
        pc_v_f2 <= '0;
        pc_f1 <= '0;
    end
    else 
    begin
        if (~stall)
        begin
            pc_f2 <= pc_f1;
            pc_v_f2 <= pc_v_f1;

            pc_f1 <= pc_n;
        end
    end
end
  

instr_scan 
  #(.eaddr_width_p(eaddr_width_p)
    ,.instr_width_p(instr_width_p)
   ) 
  instr_scan_1 
    (.instr_i(icache_pc_gen.instr)
     ,.scan_o(scan_instr)
    );

assign is_br = icache_pc_gen_v_i & (scan_instr.instr_scan_class == e_rvi_branch);
assign is_jal = icache_pc_gen_v_i & (scan_instr.instr_scan_class == e_rvi_jal);
assign br_target = icache_pc_gen.addr + scan_instr.imm; 
assign is_back_br = scan_instr.imm[63];
assign predict_taken = ((is_br & is_back_br) | (is_jal)) & icache_pc_gen_v_i;

endmodule
