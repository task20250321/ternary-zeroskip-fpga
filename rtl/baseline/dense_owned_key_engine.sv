`timescale 1ns/1ps

// Dense/no-skip PE engine with fixed output ownership.
// Every valid trit key consumes all five coordinates, including zero weights.
// This keeps dense semantics while removing the cross-PE reduction tree.
module dense_owned_key_engine #(
    parameter integer PE_ID              = 0,
    parameter integer NUM_PE             = 32,
    parameter integer OUT_FEATURES       = 2560,
    parameter integer ACT_WIDTH          = 8,
    parameter integer ACC_WIDTH          = 21,
    parameter integer GROUP_WIDTH        = 6,
    parameter integer LOCAL_ROW_WIDTH    = 7,
    parameter integer KEY_FIFO_DEPTH     = 8,
    parameter integer DECODE_FIFO_DEPTH  = 4
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

    output logic                                decode_entry_fire_o,
    output logic                                product_fire_o,
    output logic                                source_backpressure_o
);
    localparam integer ACT_EXT_WIDTH = ACT_WIDTH + 1;
    localparam integer SOURCE_PAYLOAD_WIDTH = ACT_WIDTH + GROUP_WIDTH + 8;
    localparam integer DECODE_PAYLOAD_WIDTH =
        ACT_WIDTH + GROUP_WIDTH + 5 + 5;

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

    logic decoder_key_valid;
    logic [4:0] decoder_nonzero;
    logic [4:0] decoder_sign;

    // Reuse the optimized dense LUT from the existing lockstep baseline.
    trit5_dense_decode_lut u_dense_decode (
        .key_i      (source_key),
        .valid_o    (decoder_key_valid),
        .nonzero_o  (decoder_nonzero),
        .sign_o     (decoder_sign)
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

    assign decoded_fifo_in_valid = source_out_valid && decoder_key_valid;
    assign decoded_fifo_in_data = {
        source_activation,
        source_local_group,
        decoder_nonzero,
        decoder_sign
    };

    // Invalid keys are consumed and flagged; valid keys enter the decoded FIFO.
    assign source_out_ready =
        !source_out_valid || !decoder_key_valid || decoded_fifo_in_ready;
    assign decode_entry_fire_o = source_out_valid && source_out_ready;
    assign source_backpressure_o = source_out_valid && !source_out_ready;

    logic signed [ACT_WIDTH-1:0] emit_activation;
    logic [GROUP_WIDTH-1:0] emit_local_group;
    logic [4:0] emit_nonzero;
    logic [4:0] emit_sign;

    assign {
        emit_activation,
        emit_local_group,
        emit_nonzero,
        emit_sign
    } = decoded_fifo_out_data;

    logic [2:0] emit_coord_q;
    logic [LOCAL_ROW_WIDTH:0] local_row_wide;
    logic [31:0] global_group_wide;
    logic [31:0] global_output_wide;
    logic output_in_range;
    logic emit_step;

    logic signed [ACT_EXT_WIDTH-1:0] activation_ext;
    logic signed [ACT_EXT_WIDTH-1:0] activation_neg;
    logic signed [ACT_EXT_WIDTH-1:0] dense_value;

    assign local_row_wide = (emit_local_group * 5) + emit_coord_q;
    assign global_group_wide = (emit_local_group * NUM_PE) + PE_ID;
    assign global_output_wide = (global_group_wide * 5) + emit_coord_q;
    assign output_in_range = (global_output_wide < OUT_FEATURES);

    assign activation_ext = {emit_activation[ACT_WIDTH-1], emit_activation};
    assign activation_neg = -$signed(activation_ext);

    always_comb begin
        if (!emit_nonzero[emit_coord_q])
            dense_value = '0;
        else if (emit_sign[emit_coord_q])
            dense_value = activation_ext;
        else
            dense_value = activation_neg;
    end

    // Dense baseline: every in-range coordinate is issued, including value 0.
    assign product_valid_o = decoded_fifo_out_valid && output_in_range;
    assign product_row_o = local_row_wide[LOCAL_ROW_WIDTH-1:0];
    assign product_data_o =
        {{(ACC_WIDTH-ACT_EXT_WIDTH){dense_value[ACT_EXT_WIDTH-1]}}, dense_value};
    assign product_fire_o = product_valid_o && product_ready_i;

    // Padded output coordinates advance without a RAM update.
    assign emit_step =
        decoded_fifo_out_valid && (!output_in_range || product_ready_i);
    assign decoded_fifo_out_ready = emit_step && (emit_coord_q == 3'd4);

    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            emit_coord_q         <= '0;
            error_invalid_key_o <= 1'b0;
        end else begin
            if (source_out_valid && source_out_ready && !decoder_key_valid)
                error_invalid_key_o <= 1'b1;

            if (emit_step) begin
                if (emit_coord_q == 3'd4)
                    emit_coord_q <= '0;
                else
                    emit_coord_q <= emit_coord_q + 1'b1;
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
