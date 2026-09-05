`timescale 1ns/1ps

// Copyright 2026 Yu Inoue
// SPDX-License-Identifier: Apache-2.0

// Scalable dense PE-owned dispatcher.
//
// The external packed stream remains input-major / sequential-global-group:
//   input i: groups 0..G-1, 32 8-bit keys per 256-bit word.
//
// NUM_PE is a multiple of 32.  One physical word targets one 32-PE block.
// For NUM_PE=128, words 0,1,2,3 target PE[0:31], [32:63], [64:95],
// [96:127], then word 4 returns to PE[0:31] for local_group=1.
module dense_owned_word_dispatcher #(
    parameter integer NUM_PE        = 32,
    parameter integer IN_FEATURES   = 6912,
    parameter integer OUT_FEATURES  = 2560,
    parameter integer ACT_WIDTH     = 8,
    parameter integer DDR_WORD_BITS = 256,
    parameter integer GROUP_WIDTH   = 6
) (
    input  logic                                clk_i,
    input  logic                                rst_i,
    input  logic                                start_i,

    input  logic                                activation_valid_i,
    output logic                                activation_ready_o,
    input  logic signed [ACT_WIDTH-1:0]         activation_data_i,

    input  logic                                weight_valid_i,
    output logic                                weight_ready_o,
    input  logic [DDR_WORD_BITS-1:0]            weight_data_i,

    input  logic [NUM_PE-1:0]                   pe_entry_ready_i,
    output logic [NUM_PE-1:0]                   pe_entry_valid_o,
    output logic signed [ACT_WIDTH-1:0]         pe_activation_o,
    output logic [NUM_PE*8-1:0]                 pe_key_o,
    output logic [GROUP_WIDTH-1:0]              pe_local_group_o,

    output logic                                all_inputs_dispatched_o,
    output logic                                busy_o,
    output logic                                all_active_lanes_ready_o,
    output logic [NUM_PE-1:0]                   active_lane_mask_o,
    output logic                                dispatch_fire_o
);
    localparam integer KEYS_PER_WORD = DDR_WORD_BITS / 8;
    localparam integer TOTAL_GROUPS = (OUT_FEATURES + 4) / 5;
    localparam integer PHYS_WORDS_PER_INPUT =
        (TOTAL_GROUPS + KEYS_PER_WORD - 1) / KEYS_PER_WORD;
    localparam integer BLOCKS_PER_LOCAL_GROUP = NUM_PE / KEYS_PER_WORD;
    localparam integer PHYS_WORD_WIDTH =
        (PHYS_WORDS_PER_INPUT <= 1) ? 1 : $clog2(PHYS_WORDS_PER_INPUT);
    localparam integer INPUT_COUNT_WIDTH =
        (IN_FEATURES <= 0) ? 1 : $clog2(IN_FEATURES + 1);

    logic active_q;
    logic [PHYS_WORD_WIDTH-1:0] word_q;
    logic [INPUT_COUNT_WIDTH-1:0] input_count_q;

    integer p;
    integer pe_base_comb;
    integer local_group_comb;
    integer global_group_comb;
    integer key_lane_comb;
    logic all_ready_comb;

    always_comb begin
        pe_key_o = '0;
        active_lane_mask_o = '0;
        all_ready_comb = 1'b1;
        local_group_comb = word_q / BLOCKS_PER_LOCAL_GROUP;
        pe_base_comb = (word_q % BLOCKS_PER_LOCAL_GROUP) * KEYS_PER_WORD;
        pe_local_group_o = local_group_comb[GROUP_WIDTH-1:0];

        for (p = 0; p < NUM_PE; p = p + 1) begin
            if ((p >= pe_base_comb) && (p < pe_base_comb + KEYS_PER_WORD)) begin
                global_group_comb = (local_group_comb * NUM_PE) + p;
                key_lane_comb = p - pe_base_comb;
                if (global_group_comb < TOTAL_GROUPS) begin
                    active_lane_mask_o[p] = 1'b1;
                    pe_key_o[p*8 +: 8] = weight_data_i[key_lane_comb*8 +: 8];
                    if (!pe_entry_ready_i[p])
                        all_ready_comb = 1'b0;
                end
            end
        end
    end

    assign all_active_lanes_ready_o = all_ready_comb;
    assign pe_activation_o = activation_data_i;

    // Atomic dispatch: all active lanes for this physical word fire together.
    assign weight_ready_o = active_q && activation_valid_i && all_ready_comb;
    assign dispatch_fire_o = weight_valid_i && weight_ready_o;

    always_comb begin
        pe_entry_valid_o = '0;
        if (dispatch_fire_o)
            pe_entry_valid_o = active_lane_mask_o;
    end

    // One activation is held for every packed word belonging to the input.
    assign activation_ready_o =
        dispatch_fire_o && (word_q == PHYS_WORDS_PER_INPUT-1);

    assign all_inputs_dispatched_o =
        !active_q && (input_count_q == IN_FEATURES);
    assign busy_o = active_q;

    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            active_q      <= 1'b0;
            word_q        <= '0;
            input_count_q <= '0;
        end else begin
            if (start_i) begin
                word_q        <= '0;
                input_count_q <= '0;
                active_q      <= (IN_FEATURES != 0);
            end else if (active_q && dispatch_fire_o) begin
                if (word_q == PHYS_WORDS_PER_INPUT-1) begin
                    word_q        <= '0;
                    input_count_q <= input_count_q + 1'b1;
                    if (input_count_q + 1'b1 >= IN_FEATURES)
                        active_q <= 1'b0;
                end else begin
                    word_q <= word_q + 1'b1;
                end
            end
        end
    end

`ifndef SYNTHESIS
    initial begin
        if (DDR_WORD_BITS != 256)
            $fatal(1, "Dense-owned baseline currently assumes 256-bit packed words");
        if (KEYS_PER_WORD != 32)
            $fatal(1, "Dense-owned baseline expects 32 keys per word");
        if (NUM_PE < KEYS_PER_WORD || (NUM_PE % KEYS_PER_WORD) != 0)
            $fatal(1, "NUM_PE must be a multiple of 32");
        if (!(NUM_PE == 32 || NUM_PE == 64 || NUM_PE == 128))
            $fatal(1, "Evaluated Dense-owned PE counts are 32/64/128");
        if (GROUP_WIDTH < 1)
            $fatal(1, "GROUP_WIDTH must be >= 1");
    end
`endif
endmodule
