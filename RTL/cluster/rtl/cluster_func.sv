// Include inside each consuming module after importing cluster_pkg.
// No include guard: each module needs its own function declarations.
  function automatic int wbits(input int p);
    case (p)
      0, 1: return 2;
      2, 3, 4: return 4;
      5, 6: return 8;
      default: return 0;
    endcase
  endfunction
  function automatic int abits(input int p);
    case (p)
      0, 2: return 4;
      1, 3, 5: return 8;
      4, 6: return 16;
      default: return 0;
    endcase
  endfunction
  function automatic pipeline_cfg_t pipeline_config(input cluster_ctrl_t cmd);
    pipeline_cfg_t cfg;
    cfg.split_mask = cmd.cim_reduce_split_mask;
    cfg.macro_en_mask = cmd.cim_macro_en_mask;
    cfg.macro_oc_mask = cmd.cim_macro_oc_mask;
    cfg.last_phase = 2'(abits(int'(cmd.cim_precision))/4-1);
    cfg.accum_mode = cmd.cim_as_cnt > 1 ? 2 : cmd.cim_os_cnt > 1 ? 1 : 0;
    return cfg;
  endfunction
  // Full split/masks travel with each issue. A uniform active reduction width
  // may change split without draining when its physical pipeline class agrees.
  function automatic bit compatible_pipeline(input pipeline_cfg_t a, input pipeline_cfg_t b);
    logic [2:0] a_class, b_class;
    a_class = pipeline_route_class(a);
    b_class = pipeline_route_class(b);
    return a.last_phase == b.last_phase && a.accum_mode == b.accum_mode &&
      (a.split_mask == b.split_mask || a_class == 3 || b_class == 3 ||
       (a_class < 3 && a_class == b_class));
  endfunction

  // 0=Reduce-1/2, 1=Reduce-4, 2=Reduce-8, 3=no effective output,
  // 4=mixed active widths (legacy same-split compatibility only).
  function automatic logic [2:0] pipeline_route_class(input pipeline_cfg_t cfg);
    logic [3:0] widths;
    int width_index;
    widths = 0;
    for (int m = 0; m < 8; m++) begin
      width_index = !cfg.split_mask[0] ? 3 : !cfg.split_mask[1+m/4] ? 2 :
                    !cfg.split_mask[3+m/2] ? 1 : 0;
      for (int c = 0; c < 4; c++)
        if (cfg.macro_en_mask[m] && merge_contributes(cfg.split_mask,cfg.macro_oc_mask,m,c))
          widths[width_index] = 1;
    end
    case (widths)
      4'b0000: return 3;
      4'b0001,4'b0010: return 0;
      4'b0100: return 1;
      4'b1000: return 2;
      default: return 4;
    endcase
  endfunction
  function automatic int first_leaf(input logic [6:0] s, input int m);
    if (!s[0]) return 0;
    if (!s[1+m/4]) return (m / 4) * 4;
    if (!s[3+m/2]) return (m / 2) * 2;
    return m;
  endfunction
  // Physical groups numbered left-to-right, retaining holes for idle groups.
  function automatic int group_of(input logic [6:0] s, input int m);
    int g;
    g = 0;
    // Fixed elaboration bound; m only controls the combinational predicate.
    for (int i = 1; i < 8; i++) if (i <= m && first_leaf(s, i) != first_leaf(s, i - 1)) g++;
    return g;
  endfunction
  // Effective leaf contribution after all merge masks up to its endpoint.
  // Local Macro issue remains controlled by its own OC mask; this demand
  // also gates Macro result and child forwarding registers.
  function automatic bit merge_contributes(input logic [6:0] split, input logic [31:0] oc, input int m, input int c);
    if (!oc[4*m+c]) return 0;
    if (!split[3+m/2] && !oc[4*((m/2)*2)+c]) return 0;
    if (!split[1+m/4] && !oc[4*((m/4)*4)+c]) return 0;
    if (!split[0] && !oc[c]) return 0;
    return 1;
  endfunction

  // Decode only this transaction's physical endpoint lanes.
  function automatic logic [31:0] pipeline_lanes(input pipeline_cfg_t cfg, input int path);
    logic [31:0] mask;
    int count, g, endpoint;
    mask = 0;
    for (int m = 0; m < 8; m++) begin
      count = 0;
      for (int n = 0; n < 8; n++)
        if (first_leaf(cfg.split_mask,n) == first_leaf(cfg.split_mask,m)) count++;
      endpoint = count <= 2 ? 0 : count == 4 ? 1 : 2;
      g = group_of(cfg.split_mask,m);
      for (int c = 0; c < 4; c++)
        if (endpoint == path && cfg.macro_en_mask[m] && merge_contributes(cfg.split_mask,cfg.macro_oc_mask,m,c))
          mask[4*g+c] = 1;
    end
    return mask;
  endfunction
