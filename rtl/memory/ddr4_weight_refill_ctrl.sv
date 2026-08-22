`timescale 1ns/1ps

// Read-only AXI4 refill controller for packed ternary-weight words.
//
// Properties:
//   * One AXI read burst is outstanding at a time.
//   * A burst is issued only when the FIFO has space for the whole burst.
//   * Bursts never cross a 4 KiB boundary.
//   * AXI data order is preserved exactly; no PE- or psum-specific reordering
//     is performed here. The current pe_array_scheduler consumes the same word
//     order that was produced by the offline packer.
module ddr4_weight_refill_ctrl #(
    parameter integer AXI_ADDR_WIDTH      = 30,
    parameter integer AXI_DATA_WIDTH      = 256,
    parameter integer AXI_ID_WIDTH        = 7,
    parameter integer AXI_ID_VALUE        = 0,
    parameter integer AXI_ADDR_USER_WIDTH = 14,
    parameter integer FIFO_COUNT_WIDTH    = 7,
    parameter integer COUNT_WIDTH         = 32,
    parameter integer MAX_BURST_BEATS     = 16
) (
    input  logic                              clk_i,
    input  logic                              reset_n_i,
    input  logic                              start_i,
    input  logic                              abort_i,
    input  logic [AXI_ADDR_WIDTH-1:0]         ddr_base_addr_i,
    input  logic [COUNT_WIDTH-1:0]            total_word_count_i,

    output logic                              busy_o,
    output logic                              done_o,
    output logic                              error_o,
    output logic [COUNT_WIDTH-1:0]            words_fetched_o,

    input  logic [FIFO_COUNT_WIDTH-1:0]       fifo_free_words_i,
    output logic                              fifo_push_valid_o,
    input  logic                              fifo_push_ready_i,
    output logic [AXI_DATA_WIDTH-1:0]         fifo_push_data_o,

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
    input  logic [1:0]                        m_axi_rresp_i,
    input  logic                              m_axi_rlast_i,
    input  logic                              m_axi_rvalid_i,
    output logic                              m_axi_rready_o
);

    localparam integer BYTES_PER_BEAT = AXI_DATA_WIDTH / 8;
    localparam integer AXI_SIZE_VALUE = $clog2(BYTES_PER_BEAT);
    localparam integer BURST_WIDTH    = 9; // 1..256 beats

    localparam logic [1:0] ST_IDLE       = 2'd0;
    localparam logic [1:0] ST_WAIT_SPACE = 2'd1;
    localparam logic [1:0] ST_SEND_AR    = 2'd2;
    localparam logic [1:0] ST_RECV_R     = 2'd3;

    localparam logic [AXI_ID_WIDTH-1:0] AXI_ID_CONST = AXI_ID_VALUE;

    logic [1:0] state_q;
    logic [AXI_ADDR_WIDTH-1:0] current_addr_q;
    logic [COUNT_WIDTH-1:0] remaining_words_q;
    logic [BURST_WIDTH-1:0] burst_beats_q;
    logic [BURST_WIDTH-1:0] beat_index_q;

    logic ar_fire;
    logic r_fire;
    logic expected_last;
    logic response_error;

    integer burst_candidate;
    integer boundary_beats;
    integer bytes_to_boundary;

    logic [BURST_WIDTH-1:0] next_burst_beats;

    always_comb begin
        burst_candidate = remaining_words_q;

        if (burst_candidate > MAX_BURST_BEATS)
            burst_candidate = MAX_BURST_BEATS;

        if (burst_candidate > fifo_free_words_i)
            burst_candidate = fifo_free_words_i;

        // AXI4 INCR bursts must not cross a 4 KiB boundary.
        bytes_to_boundary = 4096 - current_addr_q[11:0];
        boundary_beats    = bytes_to_boundary / BYTES_PER_BEAT;
        if (boundary_beats < 1)
            boundary_beats = 1;

        if (burst_candidate > boundary_beats)
            burst_candidate = boundary_beats;

        if (burst_candidate < 0)
            burst_candidate = 0;

        next_burst_beats = burst_candidate[BURST_WIDTH-1:0];
    end

    assign m_axi_arid_o    = AXI_ID_CONST;
    assign m_axi_araddr_o  = current_addr_q;
    assign m_axi_arlen_o   = burst_beats_q[7:0] - 1'b1;
    assign m_axi_arsize_o  = AXI_SIZE_VALUE[2:0];
    assign m_axi_arburst_o = 2'b01; // INCR
    assign m_axi_arlock_o  = 1'b0;
    assign m_axi_arprot_o  = 3'b000;
    assign m_axi_arqos_o   = 4'b0000;
    assign m_axi_aruser_o  = '0;
    assign m_axi_arvalid_o = (state_q == ST_SEND_AR);

    assign m_axi_rready_o   = (state_q == ST_RECV_R) && fifo_push_ready_i;
    assign fifo_push_valid_o = (state_q == ST_RECV_R) && m_axi_rvalid_i;
    assign fifo_push_data_o  = m_axi_rdata_i;

    assign ar_fire = m_axi_arvalid_o && m_axi_arready_i;
    assign r_fire  = m_axi_rvalid_i && m_axi_rready_o;

    assign expected_last = (beat_index_q == (burst_beats_q - 1'b1));
    assign response_error = (m_axi_rresp_i != 2'b00) ||
                            (m_axi_rid_i != AXI_ID_CONST) ||
                            (m_axi_rlast_i != expected_last);

    always_ff @(posedge clk_i or negedge reset_n_i) begin
        if (!reset_n_i) begin
            state_q           <= ST_IDLE;
            current_addr_q    <= '0;
            remaining_words_q <= '0;
            burst_beats_q     <= '0;
            beat_index_q      <= '0;
            busy_o            <= 1'b0;
            done_o            <= 1'b0;
            error_o           <= 1'b0;
            words_fetched_o   <= '0;
        end else begin
            done_o <= 1'b0;

            if (abort_i && (state_q != ST_IDLE)) begin
                state_q <= ST_IDLE;
                busy_o  <= 1'b0;
                error_o <= 1'b1;
            end else begin
                case (state_q)
                    ST_IDLE: begin
                        busy_o <= 1'b0;

                        if (start_i) begin
                            current_addr_q    <= ddr_base_addr_i;
                            remaining_words_q <= total_word_count_i;
                            words_fetched_o   <= '0;
                            burst_beats_q     <= '0;
                            beat_index_q      <= '0;
                            error_o           <= 1'b0;

                            if (ddr_base_addr_i[AXI_SIZE_VALUE-1:0] != '0) begin
                                error_o <= 1'b1;
                                done_o  <= 1'b1;
                            end else if (total_word_count_i == 0) begin
                                done_o <= 1'b1;
                            end else begin
                                busy_o  <= 1'b1;
                                state_q <= ST_WAIT_SPACE;
                            end
                        end
                    end

                    ST_WAIT_SPACE: begin
                        if (next_burst_beats != 0) begin
                            burst_beats_q <= next_burst_beats;
                            beat_index_q  <= '0;
                            state_q       <= ST_SEND_AR;
                        end
                    end

                    ST_SEND_AR: begin
                        if (ar_fire)
                            state_q <= ST_RECV_R;
                    end

                    ST_RECV_R: begin
                        if (r_fire) begin
                            words_fetched_o   <= words_fetched_o + 1'b1;
                            remaining_words_q <= remaining_words_q - 1'b1;
                            current_addr_q    <= current_addr_q + BYTES_PER_BEAT;

                            if (response_error) begin
                                error_o <= 1'b1;
                                busy_o  <= 1'b0;
                                done_o  <= 1'b1;
                                state_q <= ST_IDLE;
                            end else if (expected_last) begin
                                beat_index_q <= '0;

                                if (remaining_words_q == 1) begin
                                    busy_o  <= 1'b0;
                                    done_o  <= 1'b1;
                                    state_q <= ST_IDLE;
                                end else begin
                                    state_q <= ST_WAIT_SPACE;
                                end
                            end else begin
                                beat_index_q <= beat_index_q + 1'b1;
                            end
                        end
                    end

                    default: begin
                        state_q <= ST_IDLE;
                        busy_o  <= 1'b0;
                        error_o <= 1'b1;
                    end
                endcase
            end
        end
    end

    initial begin
        if (AXI_DATA_WIDTH < 8 || (AXI_DATA_WIDTH % 8) != 0)
            $fatal(1, "ddr4_weight_refill_ctrl: AXI_DATA_WIDTH must be byte-aligned");
        if ((BYTES_PER_BEAT & (BYTES_PER_BEAT - 1)) != 0)
            $fatal(1, "ddr4_weight_refill_ctrl: bytes per beat must be a power of two");
        if (AXI_SIZE_VALUE > 7)
            $fatal(1, "ddr4_weight_refill_ctrl: AXI beat size is too large");
        if (MAX_BURST_BEATS < 1 || MAX_BURST_BEATS > 256)
            $fatal(1, "ddr4_weight_refill_ctrl: MAX_BURST_BEATS must be 1..256");
    end

endmodule
