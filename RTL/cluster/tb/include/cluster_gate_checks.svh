// Independent endpoint walk for child output clock demand. Decode the endpoint
// top-down, then inspect each fixed-leftmost mask on this leaf's merge path.
function automatic bit expected_result_demand(input cluster_ctrl_t cmd, input int m, c);
  int node, first, size;
  node=0;first=0;size=8;
  while(size>1 && cmd.cim_reduce_split_mask[node]) begin
    size/=2;
    if(m>=first+size) begin first+=size;node=2*node+2;end
    else node=2*node+1;
  end
  for(int width=1;width<=size;width*=2)
    if(!cmd.cim_macro_oc_mask[4*((m/width)*width)+c]) return 0;
  return 1;
endfunction
// Physical clock checks use the pre-edge transaction/tag, never the live OC
// mask of a later Command. Root valid/control clocks deliberately keep running.
for (genvar oc=0;oc<4;oc++) begin : g_check_requant_read_isolation
  always @(negedge clock) begin
    #0.002;
    if(!reset && !(ENABLE_REQUANT && (|(dut.raw_valid & (32'h11111111 << oc)))))
      if(dut.u_requant.g_channel[oc].selected_psum !== 0 ||
         dut.u_requant.g_channel[oc].selected_multiplier !== 0 ||
         dut.u_requant.g_channel[oc].selected_shift !== 0 ||
         dut.u_requant.g_channel[oc].selected_zp !== 0)
        $fatal(1,"Masked Requant OC consumed Psum/parameter read data OC=%0d",oc);
  end
end
for (genvar lane=0;lane<32;lane++) begin : g_check_output_gate
  always @(posedge clock) begin
    bit raw_req, quant_req;
    logic [31:0] saved_raw;
    logic [7:0] saved_quant;
    int saved_context;
    if (!reset) begin
      raw_req=dut.result_done[lane];
      quant_req=ENABLE_REQUANT && dut.raw_valid[lane];
      saved_raw=dut.raw_data[32*lane+:32];
      saved_context=dut.raw_context[lane];
      saved_quant=requant_data_o[8*lane+:8];
      #0.002;
      if(!reset) begin
        if(dut.g_output_lane[lane].raw_clock !== raw_req ||
           dut.g_output_lane[lane].quant_clock !== quant_req)
          $fatal(1,"Output lane clock mismatch lane=%0d",lane);
        if(!raw_req && (dut.raw_data[32*lane+:32] !== saved_raw || dut.raw_context[lane] != saved_context))
          $fatal(1,"Gated raw payload changed lane=%0d",lane);
        if(!quant_req && requant_data_o[8*lane+:8] !== saved_quant)
          $fatal(1,"Gated INT8 payload changed lane=%0d",lane);
      end
    end
  end
end
for (genvar macro_id=0;macro_id<8;macro_id++) begin : g_check_macro_gate
  for(genvar oc=0;oc<4;oc++) begin : g_oc
    always @(posedge clock) begin
      bit want;
      bit consumer;
      logic [17:0] saved;
      if(!reset) begin
        consumer=expected_result_demand(dut.in_tag.cmd,macro_id,oc);
        if(dut.g_macro[macro_id].u_macro.in_valid &&
           dut.g_macro[macro_id].u_macro.result_mask_in[oc] !== consumer)
          $fatal(1,"Macro consumer request not aligned ahead of result macro=%0d OC=%0d",macro_id,oc);
        want=dut.g_macro[macro_id].u_macro.in_valid &&
             dut.g_macro[macro_id].u_macro.mask_in[oc] && consumer;
        saved=dut.macro_data[72*macro_id+18*oc+:18];
        #0.002;
        if(!reset) begin
          if(dut.g_macro[macro_id].u_macro.g_oc[oc].result_clock !== want)
            $fatal(1,"Macro OC clock mismatch macro=%0d OC=%0d",macro_id,oc);
          if(!want && dut.macro_data[72*macro_id+18*oc+:18] !== saved)
            $fatal(1,"Masked Macro OC payload changed macro=%0d OC=%0d",macro_id,oc);
        end
      end
    end
  end
  always @(posedge clock) begin
    bit compute_req, memory_req, hold_req;
    if(!reset) begin
      compute_req=dut.ren[macro_id] || dut.g_macro[macro_id].u_macro.in_valid ||
                  dut.g_macro[macro_id].u_macro.cim_odata_valid;
      memory_req=dut.memory_wen[macro_id] || (dut.regular_read && dut.regular_macro_id==macro_id) ||
                 (dut.ren[macro_id] && dut.station[macro_id]);
      hold_req=dut.memory_wen[macro_id] ||
               (dut.g_macro[macro_id].u_macro.in_valid && dut.g_macro[macro_id].u_macro.station_in);
      #0.002;
      if(!reset && (dut.g_macro[macro_id].u_macro.macro_clock !== compute_req ||
                    dut.g_macro[macro_id].u_macro.memory_clock !== memory_req ||
                    dut.g_macro[macro_id].u_macro.hold_clock !== hold_req))
        $fatal(1,"Macro clock domain mismatch macro=%0d",macro_id);
    end
  end
end
always @(posedge clock) begin : scale_group_gate_check
  bit shared_req, extra_req, batch_req, batch_extra_req;
  logic [95:0] saved_multiplier[0:REQUANT_CONTEXT_DEPTH-1];
  logic [29:0] saved_shift[0:REQUANT_CONTEXT_DEPTH-1];
  if(!reset) begin
    shared_req=ENABLE_REQUANT && ((dut.batch_active && dut.batch_command.cim_as_cnt>1) ||
                                (dut.cmd_accept && cmd_i.cim_as_cnt>1));
    extra_req=shared_req && (dut.batch_active ? dut.batch_requant_cfg.requant_mode : requant_cfg_i.requant_mode);
    batch_req=ENABLE_REQUANT && dut.cmd_accept && !dut.batch_active;
    batch_extra_req=batch_req && requant_cfg_i.requant_mode;
    for(int d=0;d<REQUANT_CONTEXT_DEPTH;d++) begin
      saved_multiplier[d]=dut.requant_context_multiplier[d][127:32];
      saved_shift[d]=dut.requant_context_shift[d][39:10];
    end
    #0.002;
    if(!reset) begin
      if(dut.channel_scale_clock !== extra_req || dut.batch_cfg_clock !== batch_req ||
         dut.batch_channel_clock !== batch_extra_req)
        $fatal(1,"Requant parameter group clock mismatch");
      if(!extra_req)
        for(int d=0;d<REQUANT_CONTEXT_DEPTH;d++)
          if(dut.requant_context_multiplier[d][127:32] !== saved_multiplier[d] ||
             dut.requant_context_shift[d][39:10] !== saved_shift[d])
            $fatal(1,"Disabled per-channel scale registers changed");
    end
  end
end

// Pair adders are fed directly by Macro output DFFs. Closing both source
// clocks must hold the actual arithmetic inputs, without forcing them to zero.
for(genvar pair_id=0;pair_id<4;pair_id++) begin : g_check_pair_source_hold
  for(genvar oc=0;oc<4;oc++) begin : g_oc
    always @(posedge clock) begin
      bit left_update,right_update;
      logic signed [20:0] saved_left,saved_right,saved_adder;
      if(!reset) begin
        left_update=dut.g_macro[2*pair_id].u_macro.g_oc[oc].result_enable;
        right_update=dut.g_macro[2*pair_id+1].u_macro.g_oc[oc].result_enable;
        saved_left=dut.u_reduce.left_data[3+pair_id][oc];
        saved_right=dut.u_reduce.right_data[3+pair_id][oc];
        saved_adder=dut.u_reduce.node_adder[3+pair_id][oc];
        #0.002;
        if(!reset) begin
          if(!left_update && dut.u_reduce.left_data[3+pair_id][oc] !== saved_left)
            $fatal(1,"Closed left child changed pair adder input pair=%0d OC=%0d",pair_id,oc);
          if(!right_update && dut.u_reduce.right_data[3+pair_id][oc] !== saved_right)
            $fatal(1,"Closed right child changed pair adder input pair=%0d OC=%0d",pair_id,oc);
          if(!left_update && !right_update && dut.u_reduce.node_adder[3+pair_id][oc] !== saved_adder)
            $fatal(1,"Pair adder toggled behind closed child clocks pair=%0d OC=%0d",pair_id,oc);
        end
      end
    end
  end
end
