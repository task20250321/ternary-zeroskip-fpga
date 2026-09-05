`timescale 1ns/1ps

// Copyright 2026 Yu Inoue
// SPDX-License-Identifier: Apache-2.0

module activation_prefetch_stream #(
    parameter integer IN_FEATURES = 2560,
    parameter integer ACT_WIDTH   = 8,
    parameter integer WORD_WIDTH  = 32,
    parameter integer LANES       = WORD_WIDTH / ACT_WIDTH,
    parameter integer WORDS       = (IN_FEATURES + LANES - 1) / LANES,
    parameter integer RAM_ADDR_WIDTH = (WORDS <= 1) ? 1 : $clog2(WORDS),
    parameter integer ACT_COUNT_WIDTH = $clog2(IN_FEATURES + 1)
) (
    input  logic                         clk_i,
    input  logic                         rst_i,
    input  logic                         start_i,

    output logic                         ram_rd_en_o,
    output logic [RAM_ADDR_WIDTH-1:0]    ram_rd_addr_o,
    input  logic                         ram_rd_valid_i,
    input  logic [WORD_WIDTH-1:0]        ram_rd_data_i,

    output logic                         activation_valid_o,
    input  logic                         activation_ready_i,
    output logic signed [ACT_WIDTH-1:0]  activation_data_o,
    output logic                         done_o
);

    localparam integer LANE_WIDTH = (LANES <= 1) ? 1 : $clog2(LANES);
    localparam integer FIFO_DEPTH = 2;
    localparam integer FIFO_LEVEL_WIDTH = $clog2(FIFO_DEPTH + 1);

    logic active_q;
    logic rd_pending_q;
    logic [RAM_ADDR_WIDTH:0] next_rd_addr_q;
    logic [ACT_COUNT_WIDTH-1:0] activation_count_q;
    logic [LANE_WIDTH-1:0] lane_q;

    logic word_fifo_in_ready;
    logic word_fifo_out_valid;
    logic word_fifo_out_ready;
    logic [WORD_WIDTH-1:0] word_fifo_out_data;
    logic [FIFO_LEVEL_WIDTH-1:0] word_fifo_level;

    logic [FIFO_LEVEL_WIDTH:0] reserved_words;
    logic activation_fire;
    logic last_activation_in_word;

    rv_fifo #(
        .DATA_WIDTH (WORD_WIDTH),
        .DEPTH      (FIFO_DEPTH)
    ) u_word_fifo (
        .clk_i       (clk_i),
        .rst_i       (rst_i || start_i),
        .in_valid_i  (ram_rd_valid_i),
        .in_ready_o  (word_fifo_in_ready),
        .in_data_i   (ram_rd_data_i),
        .out_valid_o (word_fifo_out_valid),
        .out_ready_i (word_fifo_out_ready),
        .out_data_o  (word_fifo_out_data),
        .level_o     (word_fifo_level)
    );

    always_comb begin
        reserved_words = {1'b0, word_fifo_level};
        if (rd_pending_q)
            reserved_words = reserved_words + 1'b1;

        ram_rd_en_o = active_q &&
                      !rd_pending_q &&
                      (next_rd_addr_q < WORDS) &&
                      (reserved_words < FIFO_DEPTH);
        ram_rd_addr_o = next_rd_addr_q[RAM_ADDR_WIDTH-1:0];
    end

    always_comb begin
        case (lane_q)
            2'd0: activation_data_o = $signed(word_fifo_out_data[7:0]);
            2'd1: activation_data_o = $signed(word_fifo_out_data[15:8]);
            2'd2: activation_data_o = $signed(word_fifo_out_data[23:16]);
            default: activation_data_o = $signed(word_fifo_out_data[31:24]);
        endcase
    end

    assign activation_valid_o = active_q &&
                                word_fifo_out_valid &&
                                (activation_count_q < IN_FEATURES);
    assign activation_fire = activation_valid_o && activation_ready_i;
    assign last_activation_in_word =
        (lane_q == LANES-1) || (activation_count_q == IN_FEATURES-1);
    assign word_fifo_out_ready = activation_fire && last_activation_in_word;
    assign done_o = (activation_count_q == IN_FEATURES);

    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            active_q           <= 1'b0;
            rd_pending_q       <= 1'b0;
            next_rd_addr_q     <= '0;
            activation_count_q <= '0;
            lane_q             <= '0;
        end else if (start_i) begin
            active_q           <= 1'b1;
            rd_pending_q       <= 1'b0;
            next_rd_addr_q     <= '0;
            activation_count_q <= '0;
            lane_q             <= '0;
        end else begin
            if (ram_rd_en_o) begin
                rd_pending_q   <= 1'b1;
                next_rd_addr_q <= next_rd_addr_q + 1'b1;
            end

            if (ram_rd_valid_i) begin
                rd_pending_q <= 1'b0;
                if (!word_fifo_in_ready)
                    $fatal(1, "activation prefetch FIFO overflow");
            end

            if (activation_fire) begin
                activation_count_q <= activation_count_q + 1'b1;
                if (last_activation_in_word)
                    lane_q <= '0;
                else
                    lane_q <= lane_q + 1'b1;

                if (activation_count_q == IN_FEATURES-1)
                    active_q <= 1'b0;
            end
        end
    end

    initial begin
        if (WORD_WIDTH != 32 || ACT_WIDTH != 8 || LANES != 4)
            $fatal(1, "activation_prefetch_stream currently expects 4 x int8 per 32-bit word");
    end

endmodule
