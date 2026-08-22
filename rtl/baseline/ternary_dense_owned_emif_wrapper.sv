`timescale 1ns/1ps

module ternary_dense_owned_emif_wrapper #(
    parameter integer NUM_PE                  = 32,
    parameter integer IN_FEATURES             = 6912,
    parameter integer OUT_FEATURES            = 2560,
    parameter integer ACT_WIDTH               = 8,
    parameter integer ACC_WIDTH               = ACT_WIDTH + $clog2(IN_FEATURES + 1),
    parameter integer DDR_WORD_BITS           = 256,
    parameter integer LUT_IMPL                = 0,
    parameter         LUT_INIT_FILE           = "rtl/lut/trit5_lut.mem",

    // Compatibility with the existing top-level parameter list.
    parameter integer NUM_PENDING_BANKS       = 32,
    parameter integer PE_OUTPUT_FIFO_DEPTH    = 2,
    parameter integer BANK_FIFO_DEPTH         = 8,
    parameter integer ROUTER_GROUP_SIZE       = 4,
    parameter integer CLUSTER_SIZE            = 4,

    parameter integer KEY_FIFO_DEPTH          = 8,
    parameter integer DECODE_FIFO_DEPTH       = 4,
    parameter integer PRIVATE_BANK_FIFO_DEPTH = 2,
    parameter integer ADAPTER_FIFO_DEPTH      = 4,
    parameter integer ADDR_WIDTH              = (OUT_FEATURES <= 1) ? 1 : $clog2(OUT_FEATURES)
) (
    input  logic                         clk_i,
    input  logic                         rst_i,

    input  logic                         activation_clear_i,
    input  logic                         activation_word_valid_i,
    output logic                         activation_word_ready_o,
    input  logic [31:0]                  activation_word_data_i,
    output logic                         activation_loaded_o,

    input  logic                         layer_start_i,
    output logic                         layer_start_ready_o,
    output logic                         busy_o,
    output logic                         run_phase_o,

    input  logic                         weight_available_i,
    output logic                         weight_req_o,
    input  logic                         weight_req_accepted_i,
    input  logic [DDR_WORD_BITS-1:0]     weight_data_i,
    input  logic                         weight_valid_i,

    output logic                         output_valid_o,
    input  logic                         output_ready_i,
    output logic [ADDR_WIDTH-1:0]        output_index_o,
    output logic signed [ACC_WIDTH-1:0]  output_data_o,
    output logic                         layer_done_o,

    output logic                         error_invalid_key_o,
    output logic                         error_weight_adapter_overflow_o
);
    logic stream_valid;
    logic stream_ready;
    logic [DDR_WORD_BITS-1:0] stream_data;

    emif_weight_stream_to_rv #(
        .DATA_WIDTH (DDR_WORD_BITS),
        .FIFO_DEPTH (ADAPTER_FIFO_DEPTH)
    ) u_adapter (
        .clk_i                   (clk_i),
        .rst_i                   (rst_i),
        .weight_available_i      (weight_available_i),
        .weight_req_o            (weight_req_o),
        .weight_req_accepted_i   (weight_req_accepted_i),
        .weight_data_i           (weight_data_i),
        .weight_valid_i          (weight_valid_i),
        .stream_valid_o          (stream_valid),
        .stream_ready_i          (stream_ready),
        .stream_data_o           (stream_data),
        .overflow_error_o        (error_weight_adapter_overflow_o)
    );

    ternary_dense_owned_accelerator #(
        .NUM_PE                  (NUM_PE),
        .IN_FEATURES             (IN_FEATURES),
        .OUT_FEATURES            (OUT_FEATURES),
        .ACT_WIDTH               (ACT_WIDTH),
        .ACC_WIDTH               (ACC_WIDTH),
        .DDR_WORD_BITS           (DDR_WORD_BITS),
        .LUT_IMPL                (LUT_IMPL),
        .LUT_INIT_FILE           (LUT_INIT_FILE),
        .KEY_FIFO_DEPTH          (KEY_FIFO_DEPTH),
        .DECODE_FIFO_DEPTH       (DECODE_FIFO_DEPTH),
        .PRIVATE_BANK_FIFO_DEPTH (PRIVATE_BANK_FIFO_DEPTH),
        .ADDR_WIDTH              (ADDR_WIDTH)
    ) u_core (
        .clk_i                    (clk_i),
        .rst_i                    (rst_i),
        .activation_clear_i       (activation_clear_i),
        .activation_word_valid_i  (activation_word_valid_i),
        .activation_word_ready_o  (activation_word_ready_o),
        .activation_word_data_i   (activation_word_data_i),
        .activation_loaded_o      (activation_loaded_o),
        .layer_start_i            (layer_start_i),
        .layer_start_ready_o      (layer_start_ready_o),
        .busy_o                   (busy_o),
        .run_phase_o              (run_phase_o),
        .weight_valid_i           (stream_valid),
        .weight_ready_o           (stream_ready),
        .weight_data_i            (stream_data),
        .output_valid_o           (output_valid_o),
        .output_ready_i           (output_ready_i),
        .output_index_o           (output_index_o),
        .output_data_o            (output_data_o),
        .layer_done_o             (layer_done_o),
        .error_invalid_key_o      (error_invalid_key_o)
    );

endmodule
