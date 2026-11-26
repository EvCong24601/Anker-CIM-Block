# Top-level synthesis sources for SingleMacro. Paths are relative to syn/.
# The behavioral SRAM model is omitted so hdsram256w512btop links to the .db.
# The MacroWeightSRAM black box, testbench, simulation cell models, and the
# standalone CSA register wrapper are not part of this list.
../rtl/single_macro_pkg.sv
../rtl/MacroClockGate.sv
../rtl/hdsram256w512b_mbist_top.sv
../rtl/MacroWeightSRAM.sv
../rtl/MacroMul2x4.sv
../rtl/MacroSliceFusion.sv
../rtl/MacroCompress42.sv
../rtl/MacroFullWeightPairLUT.sv
../rtl/MacroW8MainEntry.sv
../rtl/MacroW8MainTreeCSA.sv
../rtl/MacroW8MainTree.sv
../rtl/MacroW8MainCorrection.sv
../rtl/MacroW8MainOC.sv
../rtl/SingleMacro.sv
