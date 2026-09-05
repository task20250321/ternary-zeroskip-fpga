// Copyright 2026 Yu Inoue
// SPDX-License-Identifier: Apache-2.0

`timescale 1ns/1ps

`include "zeroskip_active_case.svh"

module zeroskip_top (
    input  logic        CLOCK_50,
    input  logic        CPU_RESET_n,
    input  logic [9:0]  SW,
    output logic [9:0]  LEDR,

    input  logic        DDR4_REFCLK_p,

    output logic [16:0] DDR4_A,
    output logic [1:0]  DDR4_BA,
    output logic [0:0]  DDR4_BG,
    output logic        DDR4_ACT_n,
    output logic        DDR4_CKE,
    output logic        DDR4_CS_n,
    output logic        DDR4_ODT,
    output logic        DDR4_PAR,
    output logic        DDR4_RESET_n,

    output logic        DDR4_CK,
    output logic        DDR4_CK_n,

    inout  wire [31:0]  DDR4_DQ,
    inout  wire [3:0]   DDR4_DQS,
    inout  wire [3:0]   DDR4_DQS_n,

    input  logic        DDR4_ALERT_n,
    input  logic        DDR4_RZQ
);

    localparam integer AXI_ADDR_WIDTH      = 30;
    localparam integer AXI_DATA_WIDTH      = 256;
    localparam integer AXI_ID_WIDTH        = 7;
    localparam integer AXI_ADDR_USER_WIDTH = 14;
    localparam integer AXI_DATA_USER_WIDTH = 64;
    localparam integer COUNT_WIDTH         = 32;

    localparam integer NUM_PE             = `ZS_NUM_PE;
    localparam integer IN_FEATURES        = `ZS_IN_FEATURES;
    localparam integer OUT_FEATURES       = `ZS_OUT_FEATURES;
    localparam integer NUM_PENDING_BANKS  = `ZS_NUM_BANKS;
    localparam integer LUT_IMPL           = `ZS_LUT_IMPL;
    localparam integer ACT_WIDTH          = 8;
    localparam integer ACC_WIDTH          = `ZS_ACC_WIDTH;
    localparam integer WORDS_PER_INPUT    = `ZS_WORDS_PER_INPUT;
    localparam integer TOTAL_WEIGHT_WORDS = `ZS_TOTAL_WEIGHT_WORDS;
    localparam logic [29:0] WEIGHT_BASE_ADDR = `ZS_WEIGHT_DDR_BASE;
    localparam integer ADDR_WIDTH =
        (OUT_FEATURES <= 1) ? 1 : $clog2(OUT_FEATURES);

    localparam integer STREAM_FIFO_DEPTH = 64;
    localparam integer STREAM_FIFO_COUNT_WIDTH =
        $clog2(STREAM_FIFO_DEPTH + 1);

    // --------------------------------------------------------------
    // Reset and heartbeat
    // --------------------------------------------------------------
    logic [1:0] reset_sync_q;
    logic board_reset_n;
    logic emif_axi_reset_n;
    logic common_reset_n;
    logic [25:0] heartbeat_q;

    always_ff @(posedge CLOCK_50 or negedge CPU_RESET_n) begin
        if (!CPU_RESET_n)
            reset_sync_q <= 2'b00;
        else
            reset_sync_q <= {reset_sync_q[0], 1'b1};
    end

    assign board_reset_n  = reset_sync_q[1];
    assign common_reset_n = board_reset_n & emif_axi_reset_n;

    always_ff @(posedge CLOCK_50 or negedge board_reset_n) begin
        if (!board_reset_n)
            heartbeat_q <= '0;
        else
            heartbeat_q <= heartbeat_q + 1'b1;
    end

    // --------------------------------------------------------------
    // JTAG-to-Avalon Host Bridge Platform Designer subsystem
    //
    // Save it as:
    //   ip/jtag_host/zeroskip_jtag_host.qsys
    //
    // Export names:
    //   clock input  = clk
    //   reset input  = reset_n
    //   master       = m0
    //
    // If Quartus emits a different reset port name, use the generated
    // instantiation template as the source of truth and change only
    // this instance.
    // --------------------------------------------------------------
    logic [31:0] jtag_address;
    logic        jtag_read;
    logic        jtag_write;
    logic [31:0] jtag_writedata;
    logic [3:0]  jtag_byteenable;
    logic [31:0] jtag_readdata;
    logic        jtag_waitrequest;
    logic        jtag_readdatavalid;

    zeroskip_jtag_host u_jtag_host (
        .clk_clk          (CLOCK_50),
        .reset_reset      (!board_reset_n),
        .m0_address       (jtag_address),
        .m0_read          (jtag_read),
        .m0_write         (jtag_write),
        .m0_writedata     (jtag_writedata),
        .m0_byteenable    (jtag_byteenable),
        .m0_readdata      (jtag_readdata),
        .m0_waitrequest   (jtag_waitrequest),
        .m0_readdatavalid (jtag_readdatavalid)
    );

    // --------------------------------------------------------------
    // EMIF AXI4 mainband wires.
    // Host endpoint uses AW/W/B; weight streamer uses AR/R.
    // --------------------------------------------------------------
    logic [29:0]  axi_awaddr;
    logic [1:0]   axi_awburst;
    logic [6:0]   axi_awid;
    logic [7:0]   axi_awlen;
    logic         axi_awlock;
    logic [3:0]   axi_awqos;
    logic [2:0]   axi_awsize;
    logic         axi_awvalid;
    logic [13:0]  axi_awuser;
    logic [2:0]   axi_awprot;
    logic         axi_awready;

    logic [255:0] axi_wdata;
    logic [31:0]  axi_wstrb;
    logic         axi_wlast;
    logic         axi_wvalid;
    logic         axi_wready;

    logic         axi_bready;
    logic [6:0]   axi_bid;
    logic [1:0]   axi_bresp;
    logic         axi_bvalid;

    logic [29:0]  axi_araddr;
    logic [1:0]   axi_arburst;
    logic [6:0]   axi_arid;
    logic [7:0]   axi_arlen;
    logic         axi_arlock;
    logic [3:0]   axi_arqos;
    logic [2:0]   axi_arsize;
    logic         axi_arvalid;
    logic [13:0]  axi_aruser;
    logic [2:0]   axi_arprot;
    logic         axi_arready;

    logic         axi_rready;
    logic [255:0] axi_rdata;
    logic [6:0]   axi_rid;
    logic         axi_rlast;
    logic [1:0]   axi_rresp;
    logic         axi_rvalid;

    // --------------------------------------------------------------
    // DDR weight streamer
    // --------------------------------------------------------------
    logic stream_start;
    logic [29:0] stream_base_addr;
    logic [31:0] stream_word_count;
    logic stream_busy;
    logic stream_done;
    logic stream_error;
    logic fetch_busy;
    logic fetch_done;
    logic [31:0] words_fetched;
    logic [31:0] words_delivered;
    logic [STREAM_FIFO_COUNT_WIDTH-1:0] buffered_words;
    logic [STREAM_FIFO_COUNT_WIDTH-1:0] free_words;

    logic weight_req;
    logic weight_req_accepted;
    logic weight_available;
    logic [255:0] weight_data;
    logic weight_valid;

    logic [6:0] ws_awid_unused;
    logic [29:0] ws_awaddr_unused;
    logic [7:0] ws_awlen_unused;
    logic [2:0] ws_awsize_unused;
    logic [1:0] ws_awburst_unused;
    logic ws_awlock_unused;
    logic [2:0] ws_awprot_unused;
    logic [3:0] ws_awqos_unused;
    logic [13:0] ws_awuser_unused;
    logic ws_awvalid_unused;
    logic [255:0] ws_wdata_unused;
    logic [31:0] ws_wstrb_unused;
    logic ws_wlast_unused;
    logic [63:0] ws_wuser_unused;
    logic ws_wvalid_unused;
    logic ws_bready_unused;

    emif_weight_streamer #(
        .AXI_ADDR_WIDTH      (AXI_ADDR_WIDTH),
        .AXI_DATA_WIDTH      (AXI_DATA_WIDTH),
        .AXI_ID_WIDTH        (AXI_ID_WIDTH),
        .AXI_ID_VALUE        (0),
        .AXI_ADDR_USER_WIDTH (AXI_ADDR_USER_WIDTH),
        .AXI_DATA_USER_WIDTH (AXI_DATA_USER_WIDTH),
        .FIFO_DEPTH          (STREAM_FIFO_DEPTH),
        .FIFO_COUNT_WIDTH    (STREAM_FIFO_COUNT_WIDTH),
        .COUNT_WIDTH         (COUNT_WIDTH),
        .MAX_BURST_BEATS     (16)
    ) u_weight_streamer (
        .emif_clk_i            (CLOCK_50),
        .emif_reset_n_i        (common_reset_n),
        .emif_ready_i          (emif_axi_reset_n),
        .stream_start_i        (stream_start),
        .ddr_base_addr_i       (stream_base_addr),
        .total_word_count_i    (stream_word_count),
        .stream_busy_o         (stream_busy),
        .stream_done_o         (stream_done),
        .stream_error_o        (stream_error),
        .fetch_busy_o          (fetch_busy),
        .fetch_done_o          (fetch_done),
        .words_fetched_o       (words_fetched),
        .words_delivered_o     (words_delivered),
        .buffered_words_o      (buffered_words),
        .free_words_o          (free_words),
        .weight_req_i          (weight_req),
        .weight_req_accepted_o (weight_req_accepted),
        .weight_available_o    (weight_available),
        .weight_data_o         (weight_data),
        .weight_valid_o        (weight_valid),

        .m_axi_awid_o          (ws_awid_unused),
        .m_axi_awaddr_o        (ws_awaddr_unused),
        .m_axi_awlen_o         (ws_awlen_unused),
        .m_axi_awsize_o        (ws_awsize_unused),
        .m_axi_awburst_o       (ws_awburst_unused),
        .m_axi_awlock_o        (ws_awlock_unused),
        .m_axi_awprot_o        (ws_awprot_unused),
        .m_axi_awqos_o         (ws_awqos_unused),
        .m_axi_awuser_o        (ws_awuser_unused),
        .m_axi_awvalid_o       (ws_awvalid_unused),
        .m_axi_awready_i       (1'b0),
        .m_axi_wdata_o         (ws_wdata_unused),
        .m_axi_wstrb_o         (ws_wstrb_unused),
        .m_axi_wlast_o         (ws_wlast_unused),
        .m_axi_wuser_o         (ws_wuser_unused),
        .m_axi_wvalid_o        (ws_wvalid_unused),
        .m_axi_wready_i        (1'b0),
        .m_axi_bid_i           (7'b0),
        .m_axi_bresp_i         (2'b00),
        .m_axi_bvalid_i        (1'b0),
        .m_axi_bready_o        (ws_bready_unused),

        .m_axi_arid_o          (axi_arid),
        .m_axi_araddr_o        (axi_araddr),
        .m_axi_arlen_o         (axi_arlen),
        .m_axi_arsize_o        (axi_arsize),
        .m_axi_arburst_o       (axi_arburst),
        .m_axi_arlock_o        (axi_arlock),
        .m_axi_arprot_o        (axi_arprot),
        .m_axi_arqos_o         (axi_arqos),
        .m_axi_aruser_o        (axi_aruser),
        .m_axi_arvalid_o       (axi_arvalid),
        .m_axi_arready_i       (axi_arready),
        .m_axi_rid_i           (axi_rid),
        .m_axi_rdata_i         (axi_rdata),
        .m_axi_ruser_i         (64'b0),
        .m_axi_rresp_i         (axi_rresp),
        .m_axi_rlast_i         (axi_rlast),
        .m_axi_rvalid_i        (axi_rvalid),
        .m_axi_rready_o        (axi_rready)
    );

    // --------------------------------------------------------------
    // PE-owned block-cyclic Zero-skip accelerator
    // PE_OWNED_BLOCK_CYCLIC_ZEROSKIP_V1
    // OUTPUT_PARTITION_ZEROSKIP_PATCH_V1
    // --------------------------------------------------------------
    logic activation_word_valid;
    logic activation_word_ready;
    logic [31:0] activation_word_data;
    logic activation_loaded;
    logic layer_start;
    logic layer_start_ready;
    logic accelerator_busy;
    logic core_run_phase;
    logic output_valid;
    logic output_ready;
    logic [ADDR_WIDTH-1:0] output_index;
    logic signed [ACC_WIDTH-1:0] output_data;
    logic layer_done;
    logic invalid_key_error;
    logic adapter_overflow_error;

    ternary_zeroskip_pe_owned_emif_wrapper #(
        .NUM_PE                  (NUM_PE),
        .IN_FEATURES             (IN_FEATURES),
        .OUT_FEATURES            (OUT_FEATURES),
        .ACT_WIDTH               (ACT_WIDTH),
        .ACC_WIDTH               (ACC_WIDTH),
        .DDR_WORD_BITS           (AXI_DATA_WIDTH),
        .LUT_IMPL                (LUT_IMPL),
        .LUT_INIT_FILE           ("rtl/lut/trit5_lut.mem"),
        .NUM_PENDING_BANKS       (NUM_PENDING_BANKS),
        .PE_OUTPUT_FIFO_DEPTH    (2),
        .BANK_FIFO_DEPTH         (8),
        .ROUTER_GROUP_SIZE       (4),
        .ADAPTER_FIFO_DEPTH      (4),
        .ADDR_WIDTH              (ADDR_WIDTH)
    ) u_accelerator_wrapper (
        .clk_i                           (CLOCK_50),
        .rst_i                           (!common_reset_n),
        .activation_clear_i              (clear_pulse),
        .activation_word_valid_i         (activation_word_valid),
        .activation_word_ready_o         (activation_word_ready),
        .activation_word_data_i          (activation_word_data),
        .activation_loaded_o             (activation_loaded),
        .layer_start_i                   (layer_start),
        .layer_start_ready_o              (layer_start_ready),
        .busy_o                          (accelerator_busy),
        .run_phase_o                     (core_run_phase),
        .weight_available_i              (weight_available),
        .weight_req_o                    (weight_req),
        .weight_req_accepted_i           (weight_req_accepted),
        .weight_data_i                   (weight_data),
        .weight_valid_i                  (weight_valid),
        .output_valid_o                  (output_valid),
        .output_ready_i                  (output_ready),
        .output_index_o                  (output_index),
        .output_data_o                   (output_data),
        .layer_done_o                    (layer_done),
        .error_invalid_key_o             (invalid_key_error),
        .error_weight_adapter_overflow_o (adapter_overflow_error)
    );

    // --------------------------------------------------------------
    // Host endpoint + run controller
    // --------------------------------------------------------------
    logic start_pulse;
    logic clear_pulse;
    logic result_write_valid;
    logic [ADDR_WIDTH-1:0] result_write_index;
    logic signed [ACC_WIDTH-1:0] result_write_data;

    logic test_started;
    logic test_running;
    logic test_done;
    logic [31:0] layer_cycles;
    logic [31:0] core_run_cycles;
    logic protocol_error;
    logic timeout_error;

    logic [31:0] outputs_captured;
    logic [31:0] weight_words_committed;
    logic [31:0] activation_bytes_written;
    logic upload_error;
    logic aggregate_error;
    logic test_pass;
    logic test_fail;

    assign aggregate_error =
        upload_error |
        stream_error |
        invalid_key_error |
        adapter_overflow_error |
        protocol_error |
        timeout_error;

    // This pass bit reports hardware/run integrity only.
    // Numerical correctness is checked on the host after fpga_outputs.txt
    // is dumped from RESULT_BASE.
    assign test_pass =
        test_done &&
        (outputs_captured == OUT_FEATURES) &&
        (weight_words_committed == TOTAL_WEIGHT_WORDS) &&
        (activation_bytes_written >= IN_FEATURES) &&
        (words_delivered == TOTAL_WEIGHT_WORDS) &&
        !aggregate_error;

    assign test_fail = test_done && !test_pass;

    // The accelerator result stream is always accepted and mirrored into the
    // JTAG-visible result memory. Expected-output comparison is host-side.
    assign output_ready       = 1'b1;
    assign result_write_valid = output_valid && output_ready;
    assign result_write_index = output_index;
    assign result_write_data  = output_data;

    zeroskip_jtag_avmm_endpoint #(
        .IN_FEATURES              (IN_FEATURES),
        .OUT_FEATURES             (OUT_FEATURES),
        .NUM_PE                   (NUM_PE),
        .NUM_PENDING_BANKS        (NUM_PENDING_BANKS),
        .WORDS_PER_INPUT          (WORDS_PER_INPUT),
        .TOTAL_WEIGHT_WORDS       (TOTAL_WEIGHT_WORDS),
        .ACC_WIDTH                (ACC_WIDTH),
        .AXI_ADDR_WIDTH           (AXI_ADDR_WIDTH),
        .AXI_DATA_WIDTH           (AXI_DATA_WIDTH),
        .AXI_ID_WIDTH             (AXI_ID_WIDTH),
        .AXI_ADDR_USER_WIDTH      (AXI_ADDR_USER_WIDTH),
        .WEIGHT_DDR_BASE          (WEIGHT_BASE_ADDR)
    ) u_host_endpoint (
        .clk_i                     (CLOCK_50),
        .rst_n_i                   (board_reset_n),
        .avs_address_i             (jtag_address),
        .avs_read_i                (jtag_read),
        .avs_write_i               (jtag_write),
        .avs_writedata_i           (jtag_writedata),
        .avs_byteenable_i          (jtag_byteenable),
        .avs_readdata_o            (jtag_readdata),
        .avs_waitrequest_o         (jtag_waitrequest),
        .avs_readdatavalid_o       (jtag_readdatavalid),
        .start_pulse_o             (start_pulse),
        .clear_pulse_o             (clear_pulse),
        .activation_word_valid_o  (activation_word_valid),
        .activation_word_ready_i  (activation_word_ready),
        .activation_word_data_o   (activation_word_data),
        .result_write_valid_i      (result_write_valid),
        .result_write_index_i      (result_write_index),
        .result_write_data_i       (result_write_data),
        .emif_ready_i              (emif_axi_reset_n),
        .test_started_i            (test_started),
        .test_running_i            (test_running),
        .test_done_i               (test_done),
        .test_pass_i               (test_pass),
        .test_fail_i               (test_fail),
        .layer_cycles_i            (layer_cycles),
        .core_run_cycles_i         (core_run_cycles),
        .stream_words_fetched_i    (words_fetched),
        .stream_words_delivered_i  (words_delivered),
        .stream_error_i            (stream_error),
        .invalid_key_error_i       (invalid_key_error),
        .adapter_overflow_error_i  (adapter_overflow_error),
        .protocol_error_i          (protocol_error),
        .timeout_error_i           (timeout_error),
        .outputs_captured_o        (outputs_captured),
        .weight_words_committed_o  (weight_words_committed),
        .activation_bytes_written_o(activation_bytes_written),
        .upload_error_o            (upload_error),
        .m_axi_awid_o              (axi_awid),
        .m_axi_awaddr_o            (axi_awaddr),
        .m_axi_awlen_o             (axi_awlen),
        .m_axi_awsize_o            (axi_awsize),
        .m_axi_awburst_o           (axi_awburst),
        .m_axi_awlock_o            (axi_awlock),
        .m_axi_awprot_o            (axi_awprot),
        .m_axi_awqos_o             (axi_awqos),
        .m_axi_awuser_o            (axi_awuser),
        .m_axi_awvalid_o           (axi_awvalid),
        .m_axi_awready_i           (axi_awready),
        .m_axi_wdata_o             (axi_wdata),
        .m_axi_wstrb_o             (axi_wstrb),
        .m_axi_wlast_o             (axi_wlast),
        .m_axi_wvalid_o            (axi_wvalid),
        .m_axi_wready_i            (axi_wready),
        .m_axi_bid_i               (axi_bid),
        .m_axi_bresp_i             (axi_bresp),
        .m_axi_bvalid_i            (axi_bvalid),
        .m_axi_bready_o            (axi_bready)
    );

    accelerator_host_case_ctrl #(
        .TOTAL_WEIGHT_WORDS (TOTAL_WEIGHT_WORDS),
        .WEIGHT_DDR_BASE    (WEIGHT_BASE_ADDR),
        .PREFETCH_WORDS     (16),
        .TIMEOUT_WIDTH      (32)
    ) u_host_ctrl (
        .clk_i                    (CLOCK_50),
        .rst_n_i                  (common_reset_n),
        .clear_i                  (clear_pulse),
        .start_i                  (start_pulse),
        .activation_loaded_i      (activation_loaded),
        .stream_start_o           (stream_start),
        .stream_base_addr_o       (stream_base_addr),
        .stream_word_count_o      (stream_word_count),
        .stream_done_i            (stream_done),
        .stream_error_i           (stream_error),
        .stream_words_fetched_i   (words_fetched),
        .stream_words_delivered_i (words_delivered),
        .layer_start_o            (layer_start),
        .layer_start_ready_i      (layer_start_ready),
        .core_run_phase_i         (core_run_phase),
        .layer_done_i             (layer_done),
        .test_started_o           (test_started),
        .test_running_o           (test_running),
        .test_done_o              (test_done),
        .layer_cycles_o           (layer_cycles),
        .core_run_cycles_o        (core_run_cycles),
        .protocol_error_o         (protocol_error),
        .timeout_error_o          (timeout_error)
    );

    // --------------------------------------------------------------
    // DDR4 EMIF
    // --------------------------------------------------------------
    ddr4_emif u_emif (
        .s0_axi4_clock_in    (CLOCK_50),
        .s0_axi4_reset_n     (emif_axi_reset_n),
        .core_init_n         (board_reset_n),

        .s0_axi4_awaddr      (axi_awaddr),
        .s0_axi4_awburst     (axi_awburst),
        .s0_axi4_awid        (axi_awid),
        .s0_axi4_awlen       (axi_awlen),
        .s0_axi4_awlock      (axi_awlock),
        .s0_axi4_awqos       (axi_awqos),
        .s0_axi4_awsize      (axi_awsize),
        .s0_axi4_awvalid     (axi_awvalid),
        .s0_axi4_awuser      (axi_awuser),
        .s0_axi4_awprot      (axi_awprot),
        .s0_axi4_awready     (axi_awready),

        .s0_axi4_araddr      (axi_araddr),
        .s0_axi4_arburst     (axi_arburst),
        .s0_axi4_arid        (axi_arid),
        .s0_axi4_arlen       (axi_arlen),
        .s0_axi4_arlock      (axi_arlock),
        .s0_axi4_arqos       (axi_arqos),
        .s0_axi4_arsize      (axi_arsize),
        .s0_axi4_arvalid     (axi_arvalid),
        .s0_axi4_aruser      (axi_aruser),
        .s0_axi4_arprot      (axi_arprot),
        .s0_axi4_arready     (axi_arready),

        .s0_axi4_wdata       (axi_wdata),
        .s0_axi4_wstrb       (axi_wstrb),
        .s0_axi4_wlast       (axi_wlast),
        .s0_axi4_wvalid      (axi_wvalid),
        .s0_axi4_wready      (axi_wready),

        .s0_axi4_bready      (axi_bready),
        .s0_axi4_bid         (axi_bid),
        .s0_axi4_bresp       (axi_bresp),
        .s0_axi4_bvalid      (axi_bvalid),

        .s0_axi4_rready      (axi_rready),
        .s0_axi4_rdata       (axi_rdata),
        .s0_axi4_rid         (axi_rid),
        .s0_axi4_rlast       (axi_rlast),
        .s0_axi4_rresp       (axi_rresp),
        .s0_axi4_rvalid      (axi_rvalid),

        // Sideband AXI-Lite is unused.
        .s0_axi4lite_clock   (CLOCK_50),
        .s0_axi4lite_reset_n (common_reset_n),
        .s0_axi4lite_awaddr  (27'd0),
        .s0_axi4lite_awprot  (3'd0),
        .s0_axi4lite_awvalid (1'b0),
        .s0_axi4lite_awready (),
        .s0_axi4lite_araddr  (27'd0),
        .s0_axi4lite_arprot  (3'd0),
        .s0_axi4lite_arvalid (1'b0),
        .s0_axi4lite_arready (),
        .s0_axi4lite_wdata   (32'd0),
        .s0_axi4lite_wstrb   (4'd0),
        .s0_axi4lite_wvalid  (1'b0),
        .s0_axi4lite_wready  (),
        .s0_axi4lite_bready  (1'b1),
        .s0_axi4lite_bresp   (),
        .s0_axi4lite_bvalid  (),
        .s0_axi4lite_rready  (1'b1),
        .s0_axi4lite_rdata   (),
        .s0_axi4lite_rresp   (),
        .s0_axi4lite_rvalid  (),

        .mem_0_cke           (DDR4_CKE),
        .mem_0_odt           (DDR4_ODT),
        .mem_0_cs_n          (DDR4_CS_n),
        .mem_0_a             (DDR4_A),
        .mem_0_ba            (DDR4_BA),
        .mem_0_bg            (DDR4_BG),
        .mem_0_act_n         (DDR4_ACT_n),
        .mem_0_par           (DDR4_PAR),
        .mem_0_dq            (DDR4_DQ),
        .mem_0_dqs_t         (DDR4_DQS),
        .mem_0_dqs_c         (DDR4_DQS_n),
        .mem_0_alert_n       (DDR4_ALERT_n),
        .mem_0_ck_t          (DDR4_CK),
        .mem_0_ck_c          (DDR4_CK_n),
        .mem_0_reset_n       (DDR4_RESET_n),
        .oct_rzqin_0         (DDR4_RZQ),
        .ref_clk             (DDR4_REFCLK_p)
    );

    // --------------------------------------------------------------
    // LED status, active-low on DE25-Standard.
    // --------------------------------------------------------------
    always_comb begin
        LEDR = 10'h3FF;
        LEDR[0] = ~heartbeat_q[24];
        LEDR[1] = ~emif_axi_reset_n;
        LEDR[2] = ~test_started;
        LEDR[3] = ~test_running;
        LEDR[4] = ~test_done;
        LEDR[5] = ~test_pass;
        LEDR[6] = ~test_fail;
        LEDR[7] = ~(outputs_captured == OUT_FEATURES);
        LEDR[8] = ~aggregate_error;
        LEDR[9] = ~SW[9];
    end

endmodule
