int path_split_changes = 0, path_r1_r2 = 0, path_r4 = 0;
int path_empty_barriers = 0, path_chains = 0;

// Decode active widths using the independent TB endpoint walk.
function automatic int channel_route_class(cluster_ctrl_t cfg);
  int width, current_width;
  width=0;
  for (int m=0;m<8;m++)
  for (int c=0;c<4;c++)
    if (cfg.cim_macro_en_mask[m] && contributes(cfg,m,c)) begin
      current_width=span(cfg.cim_reduce_split_mask,m);
      if (width != 0 && width != current_width) return 4;
      width=current_width;
    end
  case (width)
    0:return 3;
    1,2:return 0;
    4:return 1;
    default:return 2;
  endcase
endfunction

function automatic bit path_canonical(int split);
  return ((split&1) || split==0) && ((split&2) || !(split&24)) && ((split&4) || !(split&96));
endfunction

function automatic cluster_ctrl_t uniform_config(int p,int split,int width,int mode,int os,bit sign_en);
  cluster_ctrl_t cfg;
  cfg=config_for(p,0,mode,os,sign_en);
  cfg.cim_reduce_split_mask=7'(split);
  cfg.cim_macro_en_mask=0;
  cfg.cim_act_slot_sel=0;
  for (int m=0;m<8;m++) begin
    if (span(7'(split),m)==width && m-first_leaf(7'(split),m)<wb(p)) cfg.cim_macro_en_mask[m]=1;
    cfg.cim_act_slot_sel[3*m+:3]=3'((m-first_leaf(7'(split),m))%wb(p));
  end
  return cfg;
endfunction

always @(posedge clock) begin
  if (reset_n && $test$plusargs("PATH_CLASS_TEST")) begin
    if (cmd_valid_i && cmd_ready_o) begin
      if (channel_route_class(cmd_i)==4) $fatal(1,"PATH: test violated uniform active-width constraint");
      if (offered_job>0 && cmd_i.cim_reduce_split_mask!=configs[offered_job-1].cim_reduce_split_mask &&
          compatible(cmd_i,configs[offered_job-1])) begin
        path_split_changes++;
        if (channel_route_class(cmd_i)==0 && channel_route_class(configs[offered_job-1])==0) path_r1_r2++;
        if (channel_route_class(cmd_i)==1 && channel_route_class(configs[offered_job-1])==1) path_r4++;
      end
    end
    if (command_pending && !cmd_valid_i && channel_route_class(dut.batch_command)==3)
      path_empty_barriers++;
  end
end

// Three independent streams queue both successors and present each in its ready window.
task automatic path_chain(cluster_ctrl_t a,cluster_ctrl_t b,cluster_ctrl_t c,bit same_class);
  int j;
  j=offered_job+1;
  configs[j]=a;configs[j+1]=b;configs[j+2]=c;
  fork
    begin
      for (int job=j;job<=j+2;job++) begin
        offered_job=job;
        channel_cmd(configs[job]);
      end
    end
    begin
      for (int job=j;job<=j+2;job++)
      for (int kt=0;kt<int'(configs[job].cim_os_cnt);kt++)
      for (int cx=0;cx<int'(configs[job].cim_as_cnt);cx++)
        channel_weight(8'(address(job,kt,cx)));
    end
    begin
      for (int job=j;job<=j+2;job++)
      for (int kt=0;kt<int'(configs[job].cim_os_cnt);kt++)
      for (int cx=0;cx<int'(configs[job].cim_ws_cnt);cx++)
      for (int ph=0;ph<ab(int'(configs[job].cim_precision))/4;ph++)
        channel_act(make_plane(job,kt,cx,ph));
    end
  join
  while(first_issue[j+2]<0) @(negedge clock);
  if(cmd_cycle[j+1]!=last_issue[j] || first_issue[j+1]!=last_issue[j]+1)
    $fatal(1,"PATH: empty bridge introduced avoidable first handoff bubble");
  if(same_class) begin
    if(cmd_cycle[j+2]!=last_issue[j+1] || first_issue[j+2]!=last_issue[j+1]+1)
      $fatal(1,"PATH: same-class empty bridge introduced bubble");
  end else if(cmd_cycle[j+2]!=prior_drain[j+2] || cmd_cycle[j+2]<=last_issue[j+1])
    $fatal(1,"PATH: empty bridge bypassed incompatible older transaction");
  path_chains++;
endtask

task automatic run_path_cases();
  cluster_ctrl_t a,b,c;
  int target_width;
  for(int p=0;p<7;p++)
  for(int mode=0;mode<3;mode++)
  for(int wi=0;wi<4;wi++)
  for(int split=0;split<128;split++)
  if(path_canonical(split)) begin
    target_width=1<<wi;
    a=uniform_config(p,split,target_width,mode,mode==0?1:2,1);
    if(channel_lanes(a)!=0) begin
      if(wi<2) b=uniform_config(p,wi==0?7:127,wi==0?2:1,mode,mode==0?1:3,0);
      else if(wi==2) b=uniform_config(p,split==1?5:1,4,mode,mode==0?1:3,0);
      else b=uniform_config(p,0,8,mode,mode==0?1:3,0);
      b.cim_macro_oc_mask=32'h55555555;
      b.cim_ws_cnt=1;
      b.cim_as_cnt=mode==2?2:1;
      if(wi==0) b.cim_macro_en_mask &= 8'h3f; // [2,2,2,0] when all pairs fit.
      if(wi==1) b.cim_macro_en_mask &= 8'h7f;
      compatible_pair(a,b);
    end
  end
  for(int mode=0;mode<3;mode++) begin
    // An empty command may change raw split, but cannot erase a deep cohort.
    a=uniform_config(2,1,4,mode,mode==1?2:1,1);
    a.cim_ws_cnt=1;a.cim_as_cnt=mode==2?2:1;
    b=a;b.cim_reduce_split_mask=127;b.cim_macro_en_mask=0;
    c=uniform_config(2,127,1,mode,mode==1?2:1,1);
    c.cim_ws_cnt=1;c.cim_as_cnt=mode==2?2:1;
    path_chain(a,b,c,0);
    a=uniform_config(2,0,8,mode,mode==1?2:1,1);
    a.cim_ws_cnt=1;a.cim_as_cnt=mode==2?2:1;
    c=uniform_config(2,1,4,mode,mode==1?2:1,1);
    c.cim_ws_cnt=1;c.cim_as_cnt=mode==2?2:1;
    path_chain(a,b,c,0);
    a=uniform_config(2,7,2,mode,mode==1?2:1,1);
    a.cim_ws_cnt=1;a.cim_as_cnt=mode==2?2:1;
    b=a;b.cim_reduce_split_mask=0;b.cim_macro_en_mask=0;b.cim_macro_oc_mask=0;
    c=uniform_config(2,127,1,mode,mode==1?2:1,0);
    c.cim_ws_cnt=1;c.cim_as_cnt=mode==2?2:1;
    path_chain(a,b,c,1);
  end
  a=uniform_config(2,7,2,0,1,1);
  b=uniform_config(2,127,1,0,1,0);
  c=uniform_config(2,7,2,0,1,1);c.cim_macro_en_mask=8'h3f;
  repeat(12) path_chain(a,b,c,1);
endtask
