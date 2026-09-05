`timescale 1ns/1ps

// Copyright 2026 Yu Inoue
// SPDX-License-Identifier: Apache-2.0

// DDR4 packed-weight streamer for the current shared-partial-sum accelerator.
//
// This module is intentionally independent of the partial-sum architecture.
// It preserves the offline-packed DDR word order and exposes the exact
// request/response interface consumed by:
//
//   emif_weight_stream_to_rv
//       -> ternary_zeroskip_accelerator_emif_wrapper
//       -> pe_array_scheduler
//
// One accepted weight request produces weight_valid_o exactly one cycle later.
module emif_weight_streamer #(
    parameter integer AXI_ADDR_WIDTH      = 30,
    parameter integer AXI_DATA_WIDTH      = 256,
    parameter integer AXI_ID_WIDTH        = 7,
    parameter integer AXI_ID_VALUE        = 0,
    parameter integer AXI_ADDR_USER_WIDTH = 14,
    parameter integer AXI_DATA_USER_WIDTH = 64,
    parameter integer FIFO_DEPTH          = 64,
    parameter integer FIFO_COUNT_WIDTH    = $clog2(FIFO_DEPTH + 1),
    parameter integer COUNT_WIDTH         = 32,
    parameter integer MAX_BURST_BEATS     = 16
) (
    input  logic                              emif_clk_i,
    input  logic                              emif_reset_n_i,
    input  logic                              emif_ready_i,

    input  logic                              stream_start_i,
    input  logic [AXI_ADDR_WIDTH-1:0]         ddr_base_addr_i,
    input  logic [COUNT_WIDTH-1:0]            total_word_count_i,

    output logic                              stream_busy_o,
    output logic                              stream_done_o,
    output logic                              stream_error_o,
    output logic                              fetch_busy_o,
    output logic                              fetch_done_o,
    output logic [COUNT_WIDTH-1:0]            words_fetched_o,
    output logic [COUNT_WIDTH-1:0]            words_delivered_o,
    output logic [FIFO_COUNT_WIDTH-1:0]       buffered_words_o,
    output logic [FIFO_COUNT_WIDTH-1:0]       free_words_o,

    input  logic                              weight_req_i,
    output logic                              weight_req_accepted_o,
    output logic                              weight_available_o,
    output logic [AXI_DATA_WIDTH-1:0]         weight_data_o,
    output logic                              weight_valid_o,

    // Read-only master: write channels are tied to safe idle values.
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
    output logic [(AXI_DATA_WIDTH/8)-1:0]     m_axi_wstrb_o,
    output logic                              m_axi_wlast_o,
    output logic [AXI_DATA_USER_WIDTH-1:0]    m_axi_wuser_o,
    output logic                              m_axi_wvalid_o,
    input  logic                              m_axi_wready_i,

    input  logic [AXI_ID_WIDTH-1:0]           m_axi_bid_i,
    input  logic [1:0]                        m_axi_bresp_i,
    input  logic                              m_axi_bvalid_i,
    output logic                              m_axi_bready_o,

    output logic [AXI_ID_WIDTH-1:0]           m_axi_arid_o,
    output logic [AXI_ADDR_WIDTH-1:0]         m_axi_araddr_o,
    output logic [7:0]                        m_axi_arlen_o,
    output logic [2:0]                        m_axi_arsize_o,
    output logic [1:0]                        m_axi_arburst_o,
    output logic                              m_axi_arlock_o,
    output logic [2:0]                        m_axi_arprot_o,
    output logic [3:0]                        m_axi_arqos_o,
    output logic [AXI_ADDR_USER_WIDTH-1:0]    m_axi_aruser_o,
    output logic                              m_axi_arvalid_o,
    input  logic                              m_axi_arready_i,

    input  logic [AXI_ID_WIDTH-1:0]           m_axi_rid_i,
    input  logic [AXI_DATA_WIDTH-1:0]         m_axi_rdata_i,
    input  logic [AXI_DATA_USER_WIDTH-1:0]    m_axi_ruser_i,
    input  logic [1:0]                        m_axi_rresp_i,
    input  logic                              m_axi_rlast_i,
    input  logic                              m_axi_rvalid_i,
    output logic                              m_axi_rready_o
);

    localparam logic [1:0] ST_IDLE  = 2'd0;
    localparam logic [1:0] ST_FLUSH = 2'd1;
    localparam logic [1:0] ST_RUN   = 2'd2;

    logic [1:0] state_q;

    logic [AXI_ADDR_WIDTH-1:0] base_addr_q;
    logic [COUNT_WIDTH-1:0] total_words_q;
    logic [COUNT_WIDTH-1:0] requests_accepted_q;

    logic fifo_flush_q;
    logic fifo_push_valid;
    logic fifo_push_ready;
    logic [AXI_DATA_WIDTH-1:0] fifo_push_data;
    logic fifo_pop_req;
    logic fifo_pop_accepted;
    logic fifo_pop_valid;
    logic [AXI_DATA_WIDTH-1:0] fifo_pop_data;

    logic refill_start_q;
    logic refill_abort;
    logic refill_busy;
    logic refill_done;
    logic refill_error;
    logic [COUNT_WIDTH-1:0] refill_words_fetched;

    // ------------------------------------------------------------------
    // AXI write channels are unused by this read-only weight streamer.
    // ------------------------------------------------------------------

    always_comb begin
        m_axi_awid_o    = '0;
        m_axi_awaddr_o  = '0;
        m_axi_awlen_o   = '0;
        m_axi_awsize_o  = '0;
        m_axi_awburst_o = 2'b01;
        m_axi_awlock_o  = 1'b0;
        m_axi_awprot_o  = '0;
        m_axi_awqos_o   = '0;
        m_axi_awuser_o  = '0;
        m_axi_awvalid_o = 1'b0;

        m_axi_wdata_o   = '0;
        m_axi_wstrb_o   = '0;
        m_axi_wlast_o   = 1'b0;
        m_axi_wuser_o   = '0;
        m_axi_wvalid_o  = 1'b0;

        // Accept an unexpected write response so a stale bus response cannot
        // block the shared EMIF interface. No write transaction is generated.
        m_axi_bready_o  = 1'b1;
    end

    // Explicitly consume otherwise-unused write-response and read-user inputs
    // to keep lint tools quiet without changing hardware behavior.
    logic unused_inputs;
    always_comb begin
        unused_inputs = m_axi_awready_i ^ m_axi_wready_i ^
                        ^m_axi_bid_i ^ ^m_axi_bresp_i ^ m_axi_bvalid_i ^
                        ^m_axi_ruser_i;
    end

    weight_word_fifo #(
        .DATA_WIDTH  (AXI_DATA_WIDTH),
        .DEPTH       (FIFO_DEPTH),
        .COUNT_WIDTH (FIFO_COUNT_WIDTH)
    ) u_weight_fifo (
        .clk_i            (emif_clk_i),
        .reset_n_i        (emif_reset_n_i),
        .flush_i          (fifo_flush_q),
        .push_valid_i     (fifo_push_valid),
        .push_ready_o     (fifo_push_ready),
        .push_data_i      (fifo_push_data),
        .pop_req_i        (fifo_pop_req),
        .pop_accepted_o   (fifo_pop_accepted),
        .pop_valid_o      (fifo_pop_valid),
        .pop_data_o       (fifo_pop_data),
        .level_o          (buffered_words_o),
        .free_words_o     (free_words_o)
    );

    assign fifo_pop_req = weight_req_i && weight_available_o;

    assign weight_available_o = (state_q == ST_RUN) &&
                                (buffered_words_o != 0) &&
                                (requests_accepted_q < total_words_q) &&
                                !stream_error_o;

    assign weight_req_accepted_o = fifo_pop_accepted;
    assign weight_valid_o        = fifo_pop_valid;
    assign weight_data_o         = fifo_pop_data;

    assign fetch_busy_o     = refill_busy;
    assign fetch_done_o     = refill_done;
    assign words_fetched_o  = refill_words_fetched;
    assign refill_abort     = (state_q == ST_RUN) && !emif_ready_i;

    ddr4_weight_refill_ctrl #(
        .AXI_ADDR_WIDTH      (AXI_ADDR_WIDTH),
        .AXI_DATA_WIDTH      (AXI_DATA_WIDTH),
        .AXI_ID_WIDTH        (AXI_ID_WIDTH),
        .AXI_ID_VALUE        (AXI_ID_VALUE),
        .AXI_ADDR_USER_WIDTH (AXI_ADDR_USER_WIDTH),
        .FIFO_COUNT_WIDTH    (FIFO_COUNT_WIDTH),
        .COUNT_WIDTH         (COUNT_WIDTH),
        .MAX_BURST_BEATS     (MAX_BURST_BEATS)
    ) u_refill (
        .clk_i               (emif_clk_i),
        .reset_n_i           (emif_reset_n_i),
        .start_i             (refill_start_q),
        .abort_i             (refill_abort),
        .ddr_base_addr_i     (base_addr_q),
        .total_word_count_i  (total_words_q),
        .busy_o              (refill_busy),
        .done_o              (refill_done),
        .error_o             (refill_error),
        .words_fetched_o     (refill_words_fetched),
        .fifo_free_words_i   (free_words_o),
        .fifo_push_valid_o   (fifo_push_valid),
        .fifo_push_ready_i   (fifo_push_ready),
        .fifo_push_data_o    (fifo_push_data),
        .m_axi_arid_o        (m_axi_arid_o),
        .m_axi_araddr_o      (m_axi_araddr_o),
        .m_axi_arlen_o       (m_axi_arlen_o),
        .m_axi_arsize_o      (m_axi_arsize_o),
        .m_axi_arburst_o     (m_axi_arburst_o),
        .m_axi_arlock_o      (m_axi_arlock_o),
        .m_axi_arprot_o      (m_axi_arprot_o),
        .m_axi_arqos_o       (m_axi_arqos_o),
        .m_axi_aruser_o      (m_axi_aruser_o),
        .m_axi_arvalid_o     (m_axi_arvalid_o),
        .m_axi_arready_i     (m_axi_arready_i),
        .m_axi_rid_i         (m_axi_rid_i),
        .m_axi_rdata_i       (m_axi_rdata_i),
        .m_axi_rresp_i       (m_axi_rresp_i),
        .m_axi_rlast_i       (m_axi_rlast_i),
        .m_axi_rvalid_i      (m_axi_rvalid_i),
        .m_axi_rready_o      (m_axi_rready_o)
    );

    always_ff @(posedge emif_clk_i or negedge emif_reset_n_i) begin
        if (!emif_reset_n_i) begin
            state_q                 <= ST_IDLE;
            base_addr_q             <= '0;
            total_words_q           <= '0;
            requests_accepted_q     <= '0;
            words_delivered_o       <= '0;
            stream_busy_o           <= 1'b0;
            stream_done_o           <= 1'b0;
            stream_error_o          <= 1'b0;
            fifo_flush_q            <= 1'b0;
            refill_start_q          <= 1'b0;
        end else begin
            stream_done_o  <= 1'b0;
            fifo_flush_q   <= 1'b0;
            refill_start_q <= 1'b0;

            case (state_q)
                ST_IDLE: begin
                    stream_busy_o <= 1'b0;

                    if (stream_start_i) begin
                        base_addr_q         <= ddr_base_addr_i;
                        total_words_q       <= total_word_count_i;
                        requests_accepted_q <= '0;
                        words_delivered_o   <= '0;
                        stream_error_o      <= 1'b0;
                        fifo_flush_q        <= 1'b1;

                        if (!emif_ready_i) begin
                            stream_error_o <= 1'b1;
                        end else if (total_word_count_i == 0) begin
                            stream_done_o <= 1'b1;
                        end else begin
                            stream_busy_o <= 1'b1;
                            state_q       <= ST_FLUSH;
                        end
                    end
                end

                ST_FLUSH: begin
                    // The FIFO was flushed in the preceding cycle. Start the
                    // AXI refill after the clear has taken effect.
                    refill_start_q <= 1'b1;
                    state_q        <= ST_RUN;
                end

                ST_RUN: begin
                    if (weight_req_accepted_o)
                        requests_accepted_q <= requests_accepted_q + 1'b1;

                    if (fifo_pop_valid) begin
                        words_delivered_o <= words_delivered_o + 1'b1;

                        if ((words_delivered_o + 1'b1) == total_words_q) begin
                            stream_done_o <= 1'b1;
                            stream_busy_o <= 1'b0;
                            state_q       <= ST_IDLE;
                        end
                    end

                    if (!emif_ready_i || refill_error) begin
                        stream_error_o <= 1'b1;
                        stream_busy_o  <= 1'b0;
                        fifo_flush_q   <= 1'b1;
                        state_q        <= ST_IDLE;
                    end
                end

                default: begin
                    stream_error_o <= 1'b1;
                    stream_busy_o  <= 1'b0;
                    fifo_flush_q   <= 1'b1;
                    state_q        <= ST_IDLE;
                end
            endcase
        end
    end

    initial begin
        if (AXI_DATA_WIDTH != 256)
            $warning("emif_weight_streamer: current accelerator normally uses AXI_DATA_WIDTH=256");
        if (FIFO_DEPTH < 2)
            $fatal(1, "emif_weight_streamer: FIFO_DEPTH must be >= 2");
        if (FIFO_COUNT_WIDTH < $clog2(FIFO_DEPTH + 1))
            $fatal(1, "emif_weight_streamer: FIFO_COUNT_WIDTH is too small");
        if (MAX_BURST_BEATS > FIFO_DEPTH)
            $fatal(1, "emif_weight_streamer: MAX_BURST_BEATS must not exceed FIFO_DEPTH");
    end

endmodule
