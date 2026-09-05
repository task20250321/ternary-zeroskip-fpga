`timescale 1ns/1ps

// Copyright 2026 Yu Inoue
// SPDX-License-Identifier: Apache-2.0

// One PE owns every NUM_PE-th five-trit output group.
//
// Source FIFO entry = {activation, local_group, 8-bit key}.
// The combinational trit LUT is overlapped with a decoded-group FIFO.  Only
// non-zero groups enter the decoded FIFO.  Products are emitted directly to
// this PE's private pending_sum_bank; there is no PE-to-bank router.
module pe_owned_key_engine #(
    parameter integer PE_ID              = 0,
    parameter integer NUM_PE             = 32,
    parameter integer OUT_FEATURES       = 2560,
    parameter integer ACT_WIDTH          = 8,
    parameter integer ACC_WIDTH          = 21,
    parameter integer GROUP_WIDTH        = 6,
    parameter integer LOCAL_ROW_WIDTH    = 7,
    parameter integer KEY_FIFO_DEPTH     = 8,
    parameter integer DECODE_FIFO_DEPTH  = 4,
    parameter         LUT_INIT_FILE      = "rtl/lut/trit5_lut.mem"
) (
    input  logic                                clk_i,
    input  logic                                rst_i,

    input  logic                                entry_valid_i,
    output logic                                entry_ready_o,
    input  logic signed [ACT_WIDTH-1:0]         entry_activation_i,
    input  logic [GROUP_WIDTH-1:0]              entry_local_group_i,
    input  logic [7:0]                          entry_key_i,

    output logic                                product_valid_o,
    input  logic                                product_ready_i,
    output logic [LOCAL_ROW_WIDTH-1:0]          product_row_o,
    output logic signed [ACC_WIDTH-1:0]         product_data_o,

    output logic                                idle_o,
    output logic                                error_invalid_key_o,

    // Simulation/performance visibility.
    output logic                                decode_entry_fire_o,
    output logic                                zero_group_fire_o,
    output logic                                nonzero_group_fire_o,
    output logic                                product_fire_o,
    output logic                                source_backpressure_o
);
    localparam integer ACT_EXT_WIDTH = ACT_WIDTH + 1;
    localparam integer SOURCE_PAYLOAD_WIDTH = ACT_WIDTH + GROUP_WIDTH + 8;
    localparam integer DECODE_PAYLOAD_WIDTH =
        ACT_WIDTH + GROUP_WIDTH + 5 + 3 + 15;

    logic [SOURCE_PAYLOAD_WIDTH-1:0] source_in_data;
    logic [SOURCE_PAYLOAD_WIDTH-1:0] source_out_data;
    logic source_out_valid;
    logic source_out_ready;
    logic [$clog2(KEY_FIFO_DEPTH+1)-1:0] source_level;

    logic signed [ACT_WIDTH-1:0] source_activation;
    logic [GROUP_WIDTH-1:0] source_local_group;
    logic [7:0] source_key;

    assign source_in_data = {
        entry_activation_i,
        entry_local_group_i,
        entry_key_i
    };

    rv_fifo #(
        .DATA_WIDTH (SOURCE_PAYLOAD_WIDTH),
        .DEPTH      (KEY_FIFO_DEPTH)
    ) u_key_fifo (
        .clk_i       (clk_i),
        .rst_i       (rst_i),
        .in_valid_i  (entry_valid_i),
        .in_ready_o  (entry_ready_o),
        .in_data_i   (source_in_data),
        .out_valid_o (source_out_valid),
        .out_ready_i (source_out_ready),
        .out_data_o  (source_out_data),
        .level_o     (source_level)
    );

    assign {
        source_activation,
        source_local_group,
        source_key
    } = source_out_data;

    // Current proposal/evaluation uses the combinational low-switch LUT.
    logic decoder_key_valid;
    logic [4:0] decoder_sign;
    logic [2:0] decoder_count;
    logic [14:0] decoder_coord;

    trit5_decode_lut u_decoder (
        .key_i   (source_key),
        .valid_o (decoder_key_valid),
        .sign_o  (decoder_sign),
        .count_o (decoder_count),
        .coord_o (decoder_coord)
    );

    logic decoded_fifo_in_valid;
    logic decoded_fifo_in_ready;
    logic [DECODE_PAYLOAD_WIDTH-1:0] decoded_fifo_in_data;
    logic decoded_fifo_out_valid;
    logic decoded_fifo_out_ready;
    logic [DECODE_PAYLOAD_WIDTH-1:0] decoded_fifo_out_data;
    logic [$clog2(DECODE_FIFO_DEPTH+1)-1:0] decoded_fifo_level;

    rv_fifo #(
        .DATA_WIDTH (DECODE_PAYLOAD_WIDTH),
        .DEPTH      (DECODE_FIFO_DEPTH)
    ) u_decoded_fifo (
        .clk_i       (clk_i),
        .rst_i       (rst_i),
        .in_valid_i  (decoded_fifo_in_valid),
        .in_ready_o  (decoded_fifo_in_ready),
        .in_data_i   (decoded_fifo_in_data),
        .out_valid_o (decoded_fifo_out_valid),
        .out_ready_i (decoded_fifo_out_ready),
        .out_data_o  (decoded_fifo_out_data),
        .level_o     (decoded_fifo_level)
    );

    assign decoded_fifo_in_valid =
        source_out_valid && decoder_key_valid && (decoder_count != 0);
    assign decoded_fifo_in_data = {
        source_activation,
        source_local_group,
        decoder_sign,
        decoder_count,
        decoder_coord
    };

    // Invalid and all-zero keys need no decoded FIFO slot.
    assign source_out_ready =
        !source_out_valid ||
        !decoder_key_valid ||
        (decoder_count == 0) ||
        decoded_fifo_in_ready;

    assign decode_entry_fire_o = source_out_valid && source_out_ready;
    assign zero_group_fire_o =
        decode_entry_fire_o && decoder_key_valid && (decoder_count == 0);
    assign nonzero_group_fire_o =
        decode_entry_fire_o && decoder_key_valid && (decoder_count != 0);
    assign source_backpressure_o = source_out_valid && !source_out_ready;

    logic signed [ACT_WIDTH-1:0] emit_activation;
    logic [GROUP_WIDTH-1:0] emit_local_group;
    logic [4:0] emit_sign;
    logic [2:0] emit_count;
    logic [14:0] emit_coord;

    assign {
        emit_activation,
        emit_local_group,
        emit_sign,
        emit_count,
        emit_coord
    } = decoded_fifo_out_data;

    logic [2:0] emit_slot_q;
    logic [2:0] active_coord;
    logic [LOCAL_ROW_WIDTH:0] local_row_wide;
    logic [31:0] global_group_wide;
    logic [31:0] global_output_wide;
    logic output_in_range;
    logic emit_last_slot;
    logic emit_step;

    logic signed [ACT_EXT_WIDTH-1:0] activation_ext;
    logic signed [ACT_EXT_WIDTH-1:0] activation_neg;
    logic signed [ACT_EXT_WIDTH-1:0] selected_activation;

    function automatic [2:0] coord_at(
        input logic [14:0] packed_coord,
        input logic [2:0] slot
    );
        begin
            case (slot)
                3'd0: coord_at = packed_coord[2:0];
                3'd1: coord_at = packed_coord[5:3];
                3'd2: coord_at = packed_coord[8:6];
                3'd3: coord_at = packed_coord[11:9];
                default: coord_at = packed_coord[14:12];
            endcase
        end
    endfunction

    assign active_coord = coord_at(emit_coord, emit_slot_q);
    assign local_row_wide = (emit_local_group * 5) + active_coord;
    assign global_group_wide = (emit_local_group * NUM_PE) + PE_ID;
    assign global_output_wide = (global_group_wide * 5) + active_coord;
    assign output_in_range = (global_output_wide < OUT_FEATURES);
    assign emit_last_slot = (emit_slot_q + 1 >= emit_count);

    assign activation_ext = {emit_activation[ACT_WIDTH-1], emit_activation};
    assign activation_neg = -$signed(activation_ext);
    assign selected_activation =
        emit_sign[emit_slot_q] ? activation_ext : activation_neg;

    assign product_valid_o =
        decoded_fifo_out_valid &&
        (emit_slot_q < emit_count) &&
        output_in_range;
    assign product_row_o = local_row_wide[LOCAL_ROW_WIDTH-1:0];
    assign product_data_o =
        {{(ACC_WIDTH-ACT_EXT_WIDTH){selected_activation[ACT_EXT_WIDTH-1]}},
         selected_activation};
    assign product_fire_o = product_valid_o && product_ready_i;

    assign emit_step =
        decoded_fifo_out_valid &&
        (emit_slot_q < emit_count) &&
        (!output_in_range || product_ready_i);
    assign decoded_fifo_out_ready = emit_step && emit_last_slot;

    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            emit_slot_q         <= '0;
            error_invalid_key_o <= 1'b0;
        end else begin
            if (source_out_valid && source_out_ready && !decoder_key_valid)
                error_invalid_key_o <= 1'b1;

            if (emit_step) begin
                if (emit_last_slot)
                    emit_slot_q <= '0;
                else
                    emit_slot_q <= emit_slot_q + 1'b1;
            end
        end
    end

    assign idle_o =
        (source_level == 0) &&
        (decoded_fifo_level == 0) &&
        !source_out_valid &&
        !decoded_fifo_out_valid;

`ifndef SYNTHESIS
    initial begin
        if (PE_ID < 0 || PE_ID >= NUM_PE)
            $fatal(1, "invalid PE_ID");
        if (ACC_WIDTH < ACT_EXT_WIDTH)
            $fatal(1, "ACC_WIDTH must be >= ACT_WIDTH+1");
        if (KEY_FIFO_DEPTH < 1 || DECODE_FIFO_DEPTH < 1)
            $fatal(1, "FIFO depths must be >= 1");
    end
`endif
endmodule
