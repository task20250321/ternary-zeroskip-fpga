`timescale 1ns/1ps

// Copyright 2026 Yu Inoue
// SPDX-License-Identifier: Apache-2.0

// Scalable PE-owned weight dispatcher for NUM_PE = 32, 64, or 128.
//
// A 256-bit DDR word always carries 32 independent 8-bit trit keys.
// Output-group ownership remains:
//
//   owner_pe   = global_group % NUM_PE
//   local_group= global_group / NUM_PE
//
// For NUM_PE > 32, one local-group round is delivered in multiple physical
// 256-bit words:
//   PE32  : 1 word/local-group
//   PE64  : 2 words/local-group
//   PE128 : 4 words/local-group
//
// This keeps the external packed stream in ordinary sequential global-group
// order, so DDR traffic does not increase when NUM_PE is raised.
module pe_owned_word_dispatcher #(
    parameter integer NUM_PE         = 32,
    parameter integer IN_FEATURES    = 6912,
    parameter integer OUT_FEATURES   = 2560,
    parameter integer ACT_WIDTH      = 8,
    parameter integer DDR_WORD_BITS  = 256,
    parameter integer GROUP_WIDTH    = 6
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
    localparam integer LOCAL_GROUPS_PER_PE =
        (TOTAL_GROUPS + NUM_PE - 1) / NUM_PE;
    localparam integer BLOCKS_PER_LOCAL_GROUP = NUM_PE / KEYS_PER_WORD;
    localparam integer WORD_WIDTH =
        (PHYS_WORDS_PER_INPUT <= 1) ? 1 : $clog2(PHYS_WORDS_PER_INPUT);
    localparam integer BLOCK_WIDTH =
        (BLOCKS_PER_LOCAL_GROUP <= 1) ? 1 : $clog2(BLOCKS_PER_LOCAL_GROUP);
    localparam integer INPUT_COUNT_WIDTH = $clog2(IN_FEATURES + 1);

    logic active_q;
    logic [WORD_WIDTH-1:0] word_q;
    logic [INPUT_COUNT_WIDTH-1:0] input_count_q;

    logic [BLOCK_WIDTH-1:0] block_comb;
    logic [GROUP_WIDTH-1:0] local_group_comb;
    logic all_ready_comb;

    integer p;
    integer global_group;
    integer p_block;

    always_comb begin
        block_comb = word_q % BLOCKS_PER_LOCAL_GROUP;
        local_group_comb = word_q / BLOCKS_PER_LOCAL_GROUP;

        active_lane_mask_o = '0;
        all_ready_comb = 1'b1;
        for (p = 0; p < NUM_PE; p = p + 1) begin
            p_block = p / KEYS_PER_WORD;
            global_group = (local_group_comb * NUM_PE) + p;
            if ((p_block == block_comb) && (global_group < TOTAL_GROUPS)) begin
                active_lane_mask_o[p] = 1'b1;
                if (!pe_entry_ready_i[p])
                    all_ready_comb = 1'b0;
            end
        end
    end

    assign all_active_lanes_ready_o = all_ready_comb;
    assign pe_activation_o = activation_data_i;
    assign pe_local_group_o = local_group_comb;

    generate
        genvar gp;
        for (gp = 0; gp < NUM_PE; gp = gp + 1) begin : g_lane_key
            localparam integer GP_BLOCK = gp / KEYS_PER_WORD;
            localparam integer GP_LANE  = gp % KEYS_PER_WORD;
            assign pe_key_o[gp*8 +: 8] =
                (block_comb == GP_BLOCK) ?
                    weight_data_i[GP_LANE*8 +: 8] : 8'h00;
        end
    endgenerate

    // A physical DDR word is accepted atomically by all active PE lanes that
    // belong to its 32-lane dispatch block.
    assign weight_ready_o =
        active_q && activation_valid_i && all_ready_comb;
    assign dispatch_fire_o = weight_valid_i && weight_ready_o;

    always_comb begin
        pe_entry_valid_o = '0;
        if (dispatch_fire_o)
            pe_entry_valid_o = active_lane_mask_o;
    end

    // One activation remains current until every physical packed word for that
    // logical input has been dispatched.
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
        if (DDR_WORD_BITS % 8 != 0)
            $fatal(1, "DDR_WORD_BITS must be byte aligned");
        if (NUM_PE < KEYS_PER_WORD || (NUM_PE % KEYS_PER_WORD) != 0)
            $fatal(1,
                "PE-owned scalable dispatcher requires NUM_PE to be a multiple of DDR_WORD_BITS/8");
        if (!(NUM_PE == 32 || NUM_PE == 64 || NUM_PE == 128))
            $fatal(1, "evaluated scalable PE-owned modes are PE32/64/128");
        if (GROUP_WIDTH < ((LOCAL_GROUPS_PER_PE <= 1) ? 1 : $clog2(LOCAL_GROUPS_PER_PE)))
            $fatal(1, "GROUP_WIDTH is too small");
    end
`endif
endmodule
