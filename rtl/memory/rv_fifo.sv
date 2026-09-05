`timescale 1ns/1ps

// Copyright 2026 Yu Inoue
// SPDX-License-Identifier: Apache-2.0

module rv_fifo #(
    parameter integer DATA_WIDTH = 32,
    parameter integer DEPTH      = 2
) (
    input  logic                  clk_i,
    input  logic                  rst_i,

    input  logic                  in_valid_i,
    output logic                  in_ready_o,
    input  logic [DATA_WIDTH-1:0] in_data_i,

    output logic                  out_valid_o,
    input  logic                  out_ready_i,
    output logic [DATA_WIDTH-1:0] out_data_o,

    output logic [$clog2(DEPTH+1)-1:0] level_o
);

    localparam integer PTR_WIDTH = (DEPTH <= 1) ? 1 : $clog2(DEPTH);
    localparam integer CNT_WIDTH = $clog2(DEPTH + 1);

    logic [DATA_WIDTH-1:0] mem [0:DEPTH-1];
    logic [PTR_WIDTH-1:0]  rd_ptr_q;
    logic [PTR_WIDTH-1:0]  wr_ptr_q;
    logic [CNT_WIDTH-1:0]  count_q;

    logic push;
    logic pop;

    assign in_ready_o  = (count_q < DEPTH);
    assign out_valid_o = (count_q != 0);
    assign out_data_o  = mem[rd_ptr_q];
    assign level_o     = count_q;

    assign push = in_valid_i && in_ready_o;
    assign pop  = out_valid_o && out_ready_i;

    function automatic [PTR_WIDTH-1:0] ptr_inc(input [PTR_WIDTH-1:0] ptr);
        begin
            if (DEPTH <= 1)
                ptr_inc = {PTR_WIDTH{1'b0}};
            else if (ptr == DEPTH-1)
                ptr_inc = {PTR_WIDTH{1'b0}};
            else
                ptr_inc = ptr + 1'b1;
        end
    endfunction

    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            rd_ptr_q <= '0;
            wr_ptr_q <= '0;
            count_q  <= '0;
        end else begin
            if (push) begin
                mem[wr_ptr_q] <= in_data_i;
                wr_ptr_q      <= ptr_inc(wr_ptr_q);
            end

            if (pop)
                rd_ptr_q <= ptr_inc(rd_ptr_q);

            case ({push, pop})
                2'b10: count_q <= count_q + 1'b1;
                2'b01: count_q <= count_q - 1'b1;
                default: count_q <= count_q;
            endcase
        end
    end

    initial begin
        if (DEPTH < 1)
            $fatal(1, "rv_fifo DEPTH must be >= 1");
    end

endmodule
