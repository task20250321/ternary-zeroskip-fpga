`timescale 1ns/1ps

// Copyright 2026 Yu Inoue
// SPDX-License-Identifier: Apache-2.0

// JTAG/Avalon host endpoint.
//
// Address map:
//   0x0000_0000 : compressed-weight upload window
//   0x1000_0000 : activation upload window
//   0x2000_0000 : reserved legacy expected-output window (not stored)
//   0x2100_0000 : FPGA result readback window
//   0x3000_0000 : control/status registers
//
// Numerical correctness is checked on the host after RESULT_BASE is dumped.
// The FPGA no longer stores expected outputs or performs result-vs-expected
// comparison internally.
module zeroskip_jtag_avmm_endpoint #(
    parameter integer IN_FEATURES             = 2560,
    parameter integer OUT_FEATURES            = 640,
    parameter integer NUM_PE                  = 8,
    parameter integer NUM_PENDING_BANKS       = 16,
    parameter integer WORDS_PER_INPUT         = 4,
    parameter integer TOTAL_WEIGHT_WORDS      = 10240,
    parameter integer ACC_WIDTH               = 20,
    parameter integer AXI_ADDR_WIDTH          = 30,
    parameter integer AXI_DATA_WIDTH          = 256,
    parameter integer AXI_ID_WIDTH            = 7,
    parameter integer AXI_ADDR_USER_WIDTH     = 14,
    parameter logic [AXI_ADDR_WIDTH-1:0] WEIGHT_DDR_BASE = 30'h00100000
) (
    input  logic                              clk_i,
    input  logic                              rst_n_i,

    input  logic [31:0]                       avs_address_i,
    input  logic                              avs_read_i,
    input  logic                              avs_write_i,
    input  logic [31:0]                       avs_writedata_i,
    input  logic [3:0]                        avs_byteenable_i,
    output logic [31:0]                       avs_readdata_o,
    output logic                              avs_waitrequest_o,
    output logic                              avs_readdatavalid_o,

    output logic                              start_pulse_o,
    output logic                              clear_pulse_o,

    output logic                              activation_word_valid_o,
    input  logic                              activation_word_ready_i,
    output logic [31:0]                       activation_word_data_o,

    input  logic                              result_write_valid_i,
    input  logic [$clog2(OUT_FEATURES)-1:0]   result_write_index_i,
    input  logic signed [ACC_WIDTH-1:0]       result_write_data_i,

    input  logic                              emif_ready_i,
    input  logic                              test_started_i,
    input  logic                              test_running_i,
    input  logic                              test_done_i,
    input  logic                              test_pass_i,
    input  logic                              test_fail_i,
    input  logic [31:0]                       layer_cycles_i,
    input  logic [31:0]                       core_run_cycles_i,
    input  logic [31:0]                       stream_words_fetched_i,
    input  logic [31:0]                       stream_words_delivered_i,
    input  logic                              stream_error_i,
    input  logic                              invalid_key_error_i,
    input  logic                              adapter_overflow_error_i,
    input  logic                              protocol_error_i,
    input  logic                              timeout_error_i,

    output logic [31:0]                       outputs_captured_o,
    output logic [31:0]                       weight_words_committed_o,
    output logic [31:0]                       activation_bytes_written_o,
    output logic                              upload_error_o,

    output logic [AXI_ID_WIDTH-1:0]           m_axi_awid_o,
    output logic [AXI_ADDR_WIDTH-1:0]         m_axi_awaddr_o,
    output logic [7:0]                        m_axi_awlen_o,
    output logic [2:0]                        m_axi_awsize_o,
    output logic [1:0]                        m_axi_awburst_o,
    output logic                              m_axi_awlock_o,
    output logic [2:0]                        m_axi_awprot_o,
    output logic [3:0]                        m_axi_awqos_o,
    output logic [AXI_ADDR_USER_WIDTH-1:0]    m_axi_awuser_o,
    output logic                              m_axi_awvalid_o,
    input  logic                              m_axi_awready_i,

    output logic [AXI_DATA_WIDTH-1:0]         m_axi_wdata_o,
    output logic [AXI_DATA_WIDTH/8-1:0]       m_axi_wstrb_o,
    output logic                              m_axi_wlast_o,
    output logic                              m_axi_wvalid_o,
    input  logic                              m_axi_wready_i,

    input  logic [AXI_ID_WIDTH-1:0]           m_axi_bid_i,
    input  logic [1:0]                        m_axi_bresp_i,
    input  logic                              m_axi_bvalid_i,
    output logic                              m_axi_bready_o
);

    localparam logic [31:0] ACT_BASE             = 32'h1000_0000;
    localparam logic [31:0] LEGACY_EXPECTED_BASE = 32'h2000_0000;
    localparam logic [31:0] RESULT_BASE          = 32'h2100_0000;
    localparam logic [31:0] CSR_BASE      = 32'h3000_0000;

    localparam logic [1:0] AXI_IDLE = 2'd0;
    localparam logic [1:0] AXI_SEND = 2'd1;
    localparam logic [1:0] AXI_RESP = 2'd2;

    // Result capture is required because JTAG readback is much slower than
    // the accelerator output stream. Keep this buffer in block RAM.
    (* ramstyle = "M20K" *)
    logic signed [31:0] result_mem [0:OUT_FEATURES-1];

    logic [255:0] weight_stage_q;
    logic [7:0]   weight_lane_valid_q;

    logic [1:0] axi_state_q;
    logic [255:0] axi_pending_data_q;
    logic [AXI_ADDR_WIDTH-1:0] axi_pending_addr_q;
    logic aw_done_q;
    logic w_done_q;

    logic read_pending_q;
    logic [31:0] read_data_q;

    integer lane;
    integer out_index;

    wire is_weight_window = (avs_address_i < ACT_BASE);
    wire is_activation_window =
        (avs_address_i >= ACT_BASE) &&
        (avs_address_i < LEGACY_EXPECTED_BASE);
    wire is_legacy_expected_window =
        (avs_address_i >= LEGACY_EXPECTED_BASE) &&
        (avs_address_i < RESULT_BASE);
    wire is_result_window =
        (avs_address_i >= RESULT_BASE) && (avs_address_i < CSR_BASE);
    wire is_csr_window = (avs_address_i >= CSR_BASE);
    wire axi_write_busy = (axi_state_q != AXI_IDLE);

    function automatic [2:0] popcount4(input logic [3:0] value);
        integer j;
        begin
            popcount4 = 3'd0;
            for (j = 0; j < 4; j = j + 1)
                popcount4 = popcount4 + value[j];
        end
    endfunction

    always_comb begin
        avs_waitrequest_o = read_pending_q;
        if (avs_write_i && is_weight_window && axi_write_busy)
            avs_waitrequest_o = 1'b1;
        if (avs_write_i && is_activation_window && !activation_word_ready_i)
            avs_waitrequest_o = 1'b1;
    end

    assign activation_word_valid_o =
        avs_write_i && is_activation_window && !avs_waitrequest_o;
    assign activation_word_data_o = avs_writedata_i;

    always_comb begin
        m_axi_awid_o    = '0;
        m_axi_awaddr_o  = axi_pending_addr_q;
        m_axi_awlen_o   = 8'd0;
        m_axi_awsize_o  = 3'd5;
        m_axi_awburst_o = 2'b01;
        m_axi_awlock_o  = 1'b0;
        m_axi_awprot_o  = 3'd0;
        m_axi_awqos_o   = 4'd0;
        m_axi_awuser_o  = '0;
        m_axi_awvalid_o = (axi_state_q == AXI_SEND) && !aw_done_q;

        m_axi_wdata_o   = axi_pending_data_q;
        m_axi_wstrb_o   = {AXI_DATA_WIDTH/8{1'b1}};
        m_axi_wlast_o   = 1'b1;
        m_axi_wvalid_o  = (axi_state_q == AXI_SEND) && !w_done_q;
        m_axi_bready_o  = (axi_state_q == AXI_RESP);
    end

    always_ff @(posedge clk_i or negedge rst_n_i) begin
        logic [31:0] csr_status;
        integer csr_word;

        if (!rst_n_i) begin
            read_pending_q      <= 1'b0;
            avs_readdatavalid_o <= 1'b0;
            avs_readdata_o      <= 32'd0;
            read_data_q         <= 32'd0;
        end else begin
            avs_readdatavalid_o <= 1'b0;

            if (read_pending_q) begin
                avs_readdata_o      <= read_data_q;
                avs_readdatavalid_o <= 1'b1;
                read_pending_q      <= 1'b0;
            end

            if (avs_read_i && !avs_waitrequest_o) begin
                if (is_result_window) begin
                    out_index = (avs_address_i - RESULT_BASE) >> 2;
                    if ((out_index >= 0) && (out_index < OUT_FEATURES))
                        read_data_q <= result_mem[out_index];
                    else
                        read_data_q <= 32'hBAD0_0001;
                end else if (is_legacy_expected_window) begin
                    // Expected outputs are no longer stored on chip.
                    read_data_q <= 32'hBAD0_0002;
                end else if (is_csr_window) begin
                    csr_word = (avs_address_i - CSR_BASE) >> 2;
                    csr_status = 32'd0;
                    csr_status[0]  = emif_ready_i;
                    csr_status[1]  = test_started_i;
                    csr_status[2]  = test_running_i;
                    csr_status[3]  = test_done_i;
                    csr_status[4]  = test_pass_i;
                    csr_status[5]  = test_fail_i;
                    csr_status[6]  = 1'b0; // reserved: external compare
                    csr_status[7]  = upload_error_o;
                    csr_status[8]  = stream_error_i;
                    csr_status[9]  = invalid_key_error_i;
                    csr_status[10] = adapter_overflow_error_i;
                    csr_status[11] = protocol_error_i;
                    csr_status[12] = timeout_error_i;

                    case (csr_word)
                        0:  read_data_q <= 32'h5A53_564D;
                        1:  read_data_q <= 32'h0002_0000;
                        2:  read_data_q <= csr_status;
                        3:  read_data_q <= IN_FEATURES;
                        4:  read_data_q <= OUT_FEATURES;
                        5:  read_data_q <= NUM_PE;
                        6:  read_data_q <= NUM_PENDING_BANKS;
                        7:  read_data_q <= WORDS_PER_INPUT;
                        8:  read_data_q <= TOTAL_WEIGHT_WORDS;
                        9:  read_data_q <= {{(32-AXI_ADDR_WIDTH){1'b0}}, WEIGHT_DDR_BASE};
                        10: read_data_q <= weight_words_committed_o;
                        11: read_data_q <= activation_bytes_written_o;
                        12: read_data_q <= 32'd0; // legacy expected count
                        13: read_data_q <= outputs_captured_o;
                        14: read_data_q <= layer_cycles_i;
                        15: read_data_q <= core_run_cycles_i;
                        16: read_data_q <= stream_words_fetched_i;
                        17: read_data_q <= stream_words_delivered_i;
                        default: read_data_q <= 32'hBAD0_C500;
                    endcase
                end else begin
                    read_data_q <= 32'hBAD0_0000;
                end
                read_pending_q <= 1'b1;
            end
        end
    end

    always_ff @(posedge clk_i or negedge rst_n_i) begin
        logic [255:0] assembled_word;
        logic [7:0] assembled_valid;
        logic [31:0] weight_offset;
        logic signed [31:0] result_extended;
        integer bytes_this_write;

        if (!rst_n_i) begin
            start_pulse_o              <= 1'b0;
            clear_pulse_o              <= 1'b0;
            outputs_captured_o         <= 32'd0;
            weight_words_committed_o   <= 32'd0;
            activation_bytes_written_o <= 32'd0;
            upload_error_o             <= 1'b0;
            weight_stage_q             <= 256'd0;
            weight_lane_valid_q        <= 8'd0;
            axi_state_q                <= AXI_IDLE;
            axi_pending_data_q         <= 256'd0;
            axi_pending_addr_q         <= '0;
            aw_done_q                  <= 1'b0;
            w_done_q                   <= 1'b0;
        end else begin
            start_pulse_o <= 1'b0;
            clear_pulse_o <= 1'b0;

            if (result_write_valid_i) begin
                result_extended =
                    {{(32-ACC_WIDTH){result_write_data_i[ACC_WIDTH-1]}},
                     result_write_data_i};
                result_mem[result_write_index_i] <= result_extended;
                outputs_captured_o <= outputs_captured_o + 1'b1;
            end

            if (avs_write_i && !avs_waitrequest_o) begin
                if (is_weight_window) begin
                    weight_offset = avs_address_i;
                    lane = avs_address_i[4:2];
                    assembled_word  = weight_stage_q;
                    assembled_valid = weight_lane_valid_q;
                    assembled_word[32*lane +: 32] = avs_writedata_i;
                    assembled_valid[lane] = 1'b1;
                    weight_stage_q      <= assembled_word;
                    weight_lane_valid_q <= assembled_valid;

                    if (lane == 7) begin
                        if (assembled_valid != 8'hFF) begin
                            upload_error_o <= 1'b1;
                        end else begin
                            axi_pending_data_q <= assembled_word;
                            axi_pending_addr_q <= WEIGHT_DDR_BASE +
                                {{(AXI_ADDR_WIDTH-28){1'b0}}, weight_offset[27:5], 5'b0};
                            axi_state_q         <= AXI_SEND;
                            aw_done_q           <= 1'b0;
                            w_done_q            <= 1'b0;
                            weight_lane_valid_q <= 8'd0;
                        end
                    end
                end else if (is_activation_window) begin
                    bytes_this_write = popcount4(avs_byteenable_i);
                    if (avs_byteenable_i != 4'hF)
                        upload_error_o <= 1'b1;
                    activation_bytes_written_o <=
                        activation_bytes_written_o + bytes_this_write;
                end else if (is_legacy_expected_window) begin
                    // Backward-compatible sink. Old host scripts may still
                    // write here; data is intentionally discarded.
                end else if (is_csr_window) begin
                    if (((avs_address_i - CSR_BASE) >> 2) == 0) begin
                        if (avs_writedata_i[0]) begin
                            start_pulse_o      <= 1'b1;
                            outputs_captured_o <= 32'd0;
                        end
                        if (avs_writedata_i[1]) begin
                            clear_pulse_o              <= 1'b1;
                            outputs_captured_o         <= 32'd0;
                            weight_words_committed_o   <= 32'd0;
                            activation_bytes_written_o <= 32'd0;
                            upload_error_o             <= 1'b0;
                            weight_lane_valid_q        <= 8'd0;
                        end
                    end
                end
            end

            case (axi_state_q)
                AXI_IDLE: begin end

                AXI_SEND: begin
                    if (m_axi_awvalid_o && m_axi_awready_i)
                        aw_done_q <= 1'b1;
                    if (m_axi_wvalid_o && m_axi_wready_i)
                        w_done_q <= 1'b1;
                    if ((aw_done_q || (m_axi_awvalid_o && m_axi_awready_i)) &&
                        (w_done_q  || (m_axi_wvalid_o  && m_axi_wready_i)))
                        axi_state_q <= AXI_RESP;
                end

                AXI_RESP: begin
                    if (m_axi_bvalid_i) begin
                        if ((m_axi_bresp_i != 2'b00) ||
                            (m_axi_bid_i != {AXI_ID_WIDTH{1'b0}}))
                            upload_error_o <= 1'b1;
                        else
                            weight_words_committed_o <= weight_words_committed_o + 1'b1;
                        axi_state_q <= AXI_IDLE;
                    end
                end

                default: begin
                    upload_error_o <= 1'b1;
                    axi_state_q    <= AXI_IDLE;
                end
            endcase
        end
    end

endmodule
