`timescale 1ns/1ps
`default_nettype none
module tb_MacroArithmetic;
    import single_macro_pkg::*;
    logic [1023:0] partial_products = '0;
    logic [1:0] weight_mode = W_MODE_2;
    logic signed_en = 0, activation_signed = 0;
    wire [3:0] weight_signed;
    wire [7:0] correction_g;
    wire [17:0] correction;
    wire signed [17:0] result;
    MacroSignControl control (.*);
    MacroWeightFusion fusion (.*);
    logic [31:0] state = 32'h1badcafe;
    integer reduction_cases = 0, fusion_cases = 0;

    function automatic logic [31:0] random_word();
        state = state ^ (state << 13);
        state = state ^ (state >> 17);
        state = state ^ (state << 5);
        return state;
    endfunction
    function automatic int column(input int bit_index);
        case (bit_index % 8)
            0: return 0;
            1,4: return 1;
            2,5: return 2;
            3,6: return 3;
            default: return 4;
        endcase
    endfunction
    task automatic random_pp();
        for (int word_index = 0; word_index < 32; word_index++)
            partial_products[32*word_index +: 32] = random_word();
    endtask
    // Reference visits each dot independently with integer column weights;
    // it does not call the DUT's reduction function or inspect its grouping.
    task automatic check_arithmetic();
        int lambda, sw, c, expected_r, expected, h;
        expected = 0; h = 0;
        for (int t = 0; t < 4; t++) begin
            expected_r = 0;
            for (int bit_index = 0; bit_index < 256; bit_index++)
                expected_r += int'(partial_products[256*t+bit_index]) << column(bit_index);
            if (expected_r > 1440) $fatal(1, "TB: PP reference outside unsigned11 bound");
            lambda = weight_mode == W_MODE_2 ? 1
                   : weight_mode == W_MODE_4 ? (1 << (2*(t%2))) : (1 << (2*t));
            sw = signed_en && (weight_mode == W_MODE_2
                 || (weight_mode == W_MODE_4 && t%2 == 1)
                 || (weight_mode == W_MODE_8 && t == 3));
            c = 14*sw + 8*int'(activation_signed) + 16*(sw ^ int'(activation_signed));
            h += lambda*c;
            expected += lambda*(expected_r - 32*c);
        end
        #1;
        if (int'(correction_g) != h/8 || correction !== 18'(-(h*32)) ||
            $signed(result) != expected)
            $fatal(1, "TB: fused arithmetic mismatch mode=%0d sg=%0d sa=%0d G=%0d/%0d S=%0d/%0d",
                   weight_mode,signed_en,activation_signed,correction_g,h/8,$signed(result),expected);
        case (weight_mode)
            W_MODE_2: if (weight_signed !== (signed_en ? 4'b1111 : 4'b0)) $fatal;
            W_MODE_4: if (weight_signed !== (signed_en ? 4'b1010 : 4'b0)) $fatal;
            W_MODE_8: if (weight_signed !== (signed_en ? 4'b1000 : 4'b0)) $fatal;
        endcase
    endtask
    initial begin : tests
        // All-zero/all-one inputs and every raw PP dot in every digit slot,
        // under every weight mode: catch bit-column AND digit-weight errors.
        for (int mode = 0; mode < 3; mode++) begin
            weight_mode = mode[1:0];
            partial_products = '0; check_arithmetic(); reduction_cases++;
            partial_products = '1; check_arithmetic(); reduction_cases++;
            for (int bit_index = 0; bit_index < 1024; bit_index++) begin
                partial_products = '0;
                partial_products[bit_index] = 1;
                check_arithmetic(); reduction_cases++;
            end
        end
        for (int trial = 0; trial < 2000; trial++) begin
            weight_mode = 2'(trial%3);
            random_pp(); check_arithmetic(); reduction_cases++;
        end
        // All legal mode/sign-control combinations with arbitrary raw dots.
        for (int mode = 0; mode < 3; mode++)
            for (int sg = 0; sg < 2; sg++)
                for (int sa = 0; sa <= sg; sa++) begin
                    weight_mode = mode[1:0];
                    signed_en = (sg != 0); activation_signed = (sa != 0);
                    for (int trial = 0; trial < 500; trial++) begin
                        if (trial == 0) partial_products = '0;
                        else if (trial == 1) partial_products = '1;
                        else random_pp();
                        check_arithmetic(); fusion_cases++;
                    end
                end
        $display("PASS arithmetic reduction_vectors=%0d fusion_vectors=%0d", reduction_cases, fusion_cases);
        $finish;
    end
endmodule
`default_nettype wire
