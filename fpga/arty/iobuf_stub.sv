// Black-box declaration of the Xilinx IOBUF primitive for the slang
// frontend. nextpnr-xilinx knows IOBUF natively; yosys' automatic inout
// lowering (iopadmap) instead produces broken OBUFs without an input path
// (bring-up 2026-07-07). T=1 -> high-Z.
(* blackbox *)
module IOBUF (
    inout  wire IO,
    output wire O,
    input  wire I,
    input  wire T
);
endmodule
