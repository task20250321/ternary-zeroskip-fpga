`timescale 1ns/1ps

// Copyright 2026 Yu Inoue
// SPDX-License-Identifier: Apache-2.0

module accelerator_host_case_ctrl #(
    parameter integer TOTAL_WEIGHT_WORDS = 10240,
    parameter logic [29:0] WEIGHT_DDR_BASE = 30'h00100000,
    parameter integer PREFETCH_WORDS = 16,
    parameter integer TIMEOUT_WIDTH = 32
) (
    input  logic        clk_i,
    input  logic        rst_n_i,
    input  logic        clear_i,
    input  logic        start_i,

    input  logic        activation_loaded_i,

    output logic        stream_start_o,
    output logic [29:0] stream_base_addr_o,
    output logic [31:0] stream_word_count_o,
    input  logic        stream_done_i,
    input  logic        stream_error_i,
    input  logic [31:0] stream_words_fetched_i,
    input  logic [31:0] stream_words_delivered_i,

    output logic        layer_start_o,
    input  logic        layer_start_ready_i,
    input  logic        core_run_phase_i,
    input  logic        layer_done_i,

    output logic        test_started_o,
    output logic        test_running_o,
    output logic        test_done_o,
    output logic [31:0] layer_cycles_o,
    output logic [31:0] core_run_cycles_o,
    output logic        protocol_error_o,
    output logic        timeout_error_o
);

    localparam logic [2:0] ST_IDLE         = 3'd0;
    localparam logic [2:0] ST_STREAM_START = 3'd1;
    localparam logic [2:0] ST_WAIT_READY   = 3'd2;
    localparam logic [2:0] ST_LAYER_START  = 3'd3;
    localparam logic [2:0] ST_RUN          = 3'd4;
    localparam logic [2:0] ST_DONE         = 3'd5;

    logic [2:0] state_q;
    logic [TIMEOUT_WIDTH-1:0] timeout_q;
    logic layer_started_q;

    always_comb begin
        stream_start_o      = (state_q == ST_STREAM_START);
        stream_base_addr_o  = WEIGHT_DDR_BASE;
        stream_word_count_o = TOTAL_WEIGHT_WORDS;
        layer_start_o       = (state_q == ST_LAYER_START);
    end

    always_ff @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) begin
            state_q            <= ST_IDLE;
            timeout_q          <= '0;
            layer_started_q    <= 1'b0;
            test_started_o     <= 1'b0;
            test_running_o     <= 1'b0;
            test_done_o        <= 1'b0;
            layer_cycles_o     <= 32'd0;
            core_run_cycles_o  <= 32'd0;
            protocol_error_o   <= 1'b0;
            timeout_error_o    <= 1'b0;
        end else if (clear_i) begin
            state_q            <= ST_IDLE;
            timeout_q          <= '0;
            layer_started_q    <= 1'b0;
            test_started_o     <= 1'b0;
            test_running_o     <= 1'b0;
            test_done_o        <= 1'b0;
            layer_cycles_o     <= 32'd0;
            core_run_cycles_o  <= 32'd0;
            protocol_error_o   <= 1'b0;
            timeout_error_o    <= 1'b0;
        end else begin
            if (test_running_o)
                timeout_q <= timeout_q + 1'b1;
            else
                timeout_q <= '0;

            if (&timeout_q) begin
                timeout_error_o <= 1'b1;
                test_running_o  <= 1'b0;
                test_done_o     <= 1'b1;
                state_q         <= ST_DONE;
            end

            if (layer_started_q && !layer_done_i)
                layer_cycles_o <= layer_cycles_o + 1'b1;
            if (layer_started_q && core_run_phase_i)
                core_run_cycles_o <= core_run_cycles_o + 1'b1;
            if (stream_error_i)
                protocol_error_o <= 1'b1;

            case (state_q)
                ST_IDLE: begin
                    test_running_o <= 1'b0;
                    if (start_i) begin
                        test_started_o    <= 1'b1;
                        test_running_o    <= 1'b1;
                        test_done_o       <= 1'b0;
                        layer_started_q   <= 1'b0;
                        layer_cycles_o    <= 32'd0;
                        core_run_cycles_o <= 32'd0;
                        protocol_error_o  <= 1'b0;
                        timeout_error_o   <= 1'b0;
                        state_q           <= ST_STREAM_START;
                    end
                end

                ST_STREAM_START:
                    state_q <= ST_WAIT_READY;

                ST_WAIT_READY: begin
                    if (activation_loaded_i &&
                        ((stream_words_fetched_i >= PREFETCH_WORDS) ||
                         (stream_words_fetched_i >= TOTAL_WEIGHT_WORDS) ||
                         stream_done_i))
                        state_q <= ST_LAYER_START;
                end

                ST_LAYER_START: begin
                    if (layer_start_ready_i) begin
                        layer_started_q <= 1'b1;
                        state_q         <= ST_RUN;
                    end
                end

                ST_RUN: begin
                    if (layer_done_i) begin
                        layer_started_q <= 1'b0;
                        test_running_o  <= 1'b0;
                        test_done_o     <= 1'b1;
                        if (stream_words_delivered_i != TOTAL_WEIGHT_WORDS)
                            protocol_error_o <= 1'b1;
                        state_q <= ST_DONE;
                    end
                end

                ST_DONE:
                    state_q <= ST_DONE;

                default: begin
                    protocol_error_o <= 1'b1;
                    test_running_o   <= 1'b0;
                    test_done_o      <= 1'b1;
                    state_q          <= ST_DONE;
                end
            endcase
        end
    end

endmodule
