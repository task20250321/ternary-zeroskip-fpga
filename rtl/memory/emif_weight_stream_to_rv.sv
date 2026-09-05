`timescale 1ns/1ps

// Copyright 2026 Yu Inoue
// SPDX-License-Identifier: Apache-2.0

// Adapter for the existing request/response EMIF weight streamer.
// It converts weight_available/weight_req/weight_valid into a ready/valid stream.
module emif_weight_stream_to_rv #(
    parameter integer DATA_WIDTH = 256,
    parameter integer FIFO_DEPTH = 4
) (
    input  logic                  clk_i,
    input  logic                  rst_i,

    input  logic                  weight_available_i,
    output logic                  weight_req_o,
    input  logic                  weight_req_accepted_i,
    input  logic [DATA_WIDTH-1:0] weight_data_i,
    input  logic                  weight_valid_i,

    output logic                  stream_valid_o,
    input  logic                  stream_ready_i,
    output logic [DATA_WIDTH-1:0] stream_data_o,

    output logic                  overflow_error_o
);

    localparam integer COUNT_WIDTH = $clog2(FIFO_DEPTH + 1);

    logic fifo_in_ready;
    logic [COUNT_WIDTH-1:0] fifo_level;
    logic [COUNT_WIDTH-1:0] outstanding_q;
    logic response_push;
    logic request_fire;

    rv_fifo #(
        .DATA_WIDTH (DATA_WIDTH),
        .DEPTH      (FIFO_DEPTH)
    ) u_fifo (
        .clk_i       (clk_i),
        .rst_i       (rst_i),
        .in_valid_i  (response_push),
        .in_ready_o  (fifo_in_ready),
        .in_data_i   (weight_data_i),
        .out_valid_o (stream_valid_o),
        .out_ready_i (stream_ready_i),
        .out_data_o  (stream_data_o),
        .level_o     (fifo_level)
    );

    assign weight_req_o = weight_available_i &&
                          ((fifo_level + outstanding_q) < FIFO_DEPTH);
    assign request_fire = weight_req_o && weight_req_accepted_i;
    assign response_push = weight_valid_i && fifo_in_ready;

    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            outstanding_q   <= '0;
            overflow_error_o<= 1'b0;
        end else begin
            if (weight_valid_i && !fifo_in_ready)
                overflow_error_o <= 1'b1;

            case ({request_fire, weight_valid_i})
                2'b10: outstanding_q <= outstanding_q + 1'b1;
                2'b01: begin
                    if (outstanding_q != 0)
                        outstanding_q <= outstanding_q - 1'b1;
                end
                default: outstanding_q <= outstanding_q;
            endcase
        end
    end

endmodule
