`timescale 1ns/1ps
// Clock-free unit test: changing inputs must settle without any clock edge.
// Python supplies exact full-range integer golden values for supported shifts.
module tb_ClusterRequant;
  import cluster_pkg::*;
  requant_cfg_t cfg_i;
  logic [1023:0] psum_i;
  logic [31:0] valid_i;
  wire [255:0] data_o;
  wire [31:0] valid_o;
  ClusterRequant dut(.*);
  initial begin
    string path,description;
    int fd,status,p,m,s,z,wanted,cases,checks;
    cases=0;checks=0;cfg_i='0;psum_i='0;valid_i='0;
    if(!$value$plusargs("REQUANT_VECTORS=%s",path))
      $fatal(1,"TB: require +REQUANT_VECTORS=PATH (generate with requant_vectors.py)");
    fd=$fopen(path,"r");
    if(!fd) $fatal(1,"TB: cannot open Requant vectors");
    while(!$feof(fd)) begin
      status=$fscanf(fd,"%d %d %d %d %d %s\n",p,m,s,z,wanted,description);
      if(status!=6) $fatal(1,"TB: malformed Requant vector row");
      $display("[CASE_START] time=%0.3f ns suite=requant_unit case=%0d description=%s psum=%0d multiplier=%0d shift=%0d zp=%0d",
        $realtime,cases,description,p,m,s,z);
      cfg_i='{requant_mode:1'b0,requant_multiplier:32'(m),requant_shift:10'(s),requant_zp:{32{32'(z)}}};
      for(int lane=0;lane<32;lane++) psum_i[32*lane+:32]=32'(p);
      case(cases%4)
        0:valid_i=32'hffffffff;
        1:valid_i=32'h00000000;
        2:valid_i=32'h81020408;
        3:valid_i=32'h55555555;
      endcase
      #0.001;
      if(valid_o!==valid_i) $fatal(1,"Requant unit valid is not combinational");
      for(int lane=0;lane<32;lane++) begin
        if(data_o[8*lane+:8]!==8'(wanted))
          $fatal(1,"Requant unit mismatch case=%0d lane=%0d got=%0d expected=%0d",
            cases,lane,$signed(data_o[8*lane+:8]),wanted);
        checks++;
      end
      cases++;
    end
    $fclose(fd);
    if(cases<9000) $fatal(1,"Missing Requant unit vector coverage");
    $display("PASS requant_unit cases=%0d lane_checks=%0d latency=0 no_clock=1",cases,checks);
    $finish;
  end
endmodule
