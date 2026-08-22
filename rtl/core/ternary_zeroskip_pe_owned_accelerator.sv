`timescale 1ns/1ps

// PE-level output ownership Zero-skip accelerator.
//
// PE p permanently owns global 5-trit groups g where g mod NUM_PE == p.
// A 256-bit DDR word carries 32 keys.  PE64/128 therefore use 2/4 physical
// words per local-group round while preserving the same sequential packed
// stream and the same off-chip traffic.  Products go directly to one private
// pending_sum_bank per PE; there is no partial-product router.
module ternary_zeroskip_pe_owned_accelerator #(
    parameter integer NUM_PE               = 32,
    parameter integer IN_FEATURES          = 6912,
    parameter integer OUT_FEATURES         = 2560,
    parameter integer ACT_WIDTH            = 8,
    parameter integer ACC_WIDTH            = ACT_WIDTH + $clog2(IN_FEATURES + 1),
    parameter integer DDR_WORD_BITS        = 256,
    parameter integer LUT_IMPL             = 0,
    parameter         LUT_INIT_FILE        = "rtl/lut/trit5_lut.mem",
    parameter integer KEY_FIFO_DEPTH       = 8,
    parameter integer DECODE_FIFO_DEPTH    = 4,
    parameter integer PRIVATE_BANK_FIFO_DEPTH = 8,
    parameter integer ADDR_WIDTH           = (OUT_FEATURES <= 1) ? 1 : $clog2(OUT_FEATURES)
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

    input  logic                         weight_valid_i,
    output logic                         weight_ready_o,
    input  logic [DDR_WORD_BITS-1:0]     weight_data_i,

    output logic                         output_valid_o,
    input  logic                         output_ready_i,
    output logic [ADDR_WIDTH-1:0]        output_index_o,
    output logic signed [ACC_WIDTH-1:0]  output_data_o,
    output logic                         layer_done_o,

    output logic                         error_invalid_key_o
);
    localparam integer KEYS_PER_WORD = DDR_WORD_BITS / 8;
    localparam integer TOTAL_GROUPS = (OUT_FEATURES + 4) / 5;
    localparam integer PHYS_WORDS_PER_INPUT =
        (TOTAL_GROUPS + KEYS_PER_WORD - 1) / KEYS_PER_WORD;
    localparam integer LOCAL_GROUPS =
        (TOTAL_GROUPS + NUM_PE - 1) / NUM_PE;
    localparam integer GROUP_WIDTH =
        (LOCAL_GROUPS <= 1) ? 1 : $clog2(LOCAL_GROUPS);
    localparam integer LOCAL_ROWS = LOCAL_GROUPS * 5;
    localparam integer LOCAL_ROW_WIDTH =
        (LOCAL_ROWS <= 1) ? 1 : $clog2(LOCAL_ROWS);
    localparam integer PE_SEL_WIDTH =
        (NUM_PE <= 1) ? 1 : $clog2(NUM_PE);

    localparam integer ACT_WORDS = (IN_FEATURES + 3) / 4;
    localparam integer ACT_RAM_ADDR_WIDTH =
        (ACT_WORDS <= 1) ? 1 : $clog2(ACT_WORDS);
    localparam integer FINAL_COUNT_WIDTH = $clog2(OUT_FEATURES + 1);
    localparam integer FINAL_RESULT_FIFO_DEPTH = 4;
    localparam integer RESULT_PAYLOAD_WIDTH = ADDR_WIDTH + ACC_WIDTH;
    localparam integer RESULT_LEVEL_WIDTH =
        $clog2(FINAL_RESULT_FIFO_DEPTH + 1);

    localparam logic [3:0] ST_IDLE         = 4'd0;
    localparam logic [3:0] ST_RUN_RESET    = 4'd1;
    localparam logic [3:0] ST_CLEAR_START  = 4'd2;
    localparam logic [3:0] ST_CLEAR_WAIT   = 4'd3;
    localparam logic [3:0] ST_SCHED_START  = 4'd4;
    localparam logic [3:0] ST_RUN          = 4'd5;
    localparam logic [3:0] ST_PIPE_DRAIN   = 4'd6;
    localparam logic [3:0] ST_FINAL_DRAIN  = 4'd7;

    logic [3:0] state_q;
    logic run_reset;

    // Activation RAM/prefetch.
    logic activation_ram_rd_en;
    logic [ACT_RAM_ADDR_WIDTH-1:0] activation_ram_rd_addr;
    logic activation_ram_rd_valid;
    logic [31:0] activation_ram_rd_data;
    logic activation_prefetch_start;
    logic activation_stream_valid;
    logic activation_stream_ready;
    logic signed [ACT_WIDTH-1:0] activation_stream_data;

    // Dispatcher and PE entries.
    logic dispatcher_start;
    logic [NUM_PE-1:0] pe_entry_ready;
    logic [NUM_PE-1:0] pe_entry_valid;
    logic signed [ACT_WIDTH-1:0] pe_entry_activation;
    logic [NUM_PE*8-1:0] pe_entry_key;
    logic [GROUP_WIDTH-1:0] pe_entry_local_group;
    logic dispatcher_all_inputs_dispatched;
    logic dispatcher_all_active_ready;
    logic [NUM_PE-1:0] dispatcher_active_lane_mask;
    logic dispatcher_fire;

    // Engines/private banks.
    logic [NUM_PE-1:0] pe_idle;
    logic [NUM_PE-1:0] pe_product_valid;
    logic [NUM_PE-1:0] pe_product_ready;
    logic [NUM_PE*LOCAL_ROW_WIDTH-1:0] pe_product_row;
    logic [NUM_PE*ACC_WIDTH-1:0] pe_product_data;
    logic [NUM_PE-1:0] pe_error_invalid_key;

    // Performance-visible engine events.
    logic [NUM_PE-1:0] pe_decode_entry_fire;
    logic [NUM_PE-1:0] pe_zero_group_fire;
    logic [NUM_PE-1:0] pe_nonzero_group_fire;
    logic [NUM_PE-1:0] pe_product_fire;
    logic [NUM_PE-1:0] pe_source_backpressure;

    // Private accumulators / final scan.
    logic pending_clear_start;
    logic pending_clear_done;
    logic pending_clear_seen_q;
    logic pending_all_fifos_empty;
    logic pending_scan_valid;
    logic pending_scan_pop;
    logic [PE_SEL_WIDTH-1:0] pending_scan_pe;
    logic [LOCAL_ROW_WIDTH-1:0] pending_scan_row;
    logic signed [ACC_WIDTH-1:0] pending_scan_data;

    logic [FINAL_COUNT_WIDTH-1:0] final_issue_count_q;
    logic [PE_SEL_WIDTH-1:0] final_scan_pe_q;
    logic [GROUP_WIDTH-1:0] final_scan_local_group_q;
    logic [2:0] final_scan_coord_q;
    logic final_issue;
    logic final_inflight_valid_q;
    logic [ADDR_WIDTH-1:0] final_inflight_addr_q;

    logic result_fifo_in_valid;
    logic result_fifo_in_ready;
    logic [RESULT_PAYLOAD_WIDTH-1:0] result_fifo_in_data;
    logic result_fifo_out_valid;
    logic result_fifo_out_ready;
    logic [RESULT_PAYLOAD_WIDTH-1:0] result_fifo_out_data;
    logic [RESULT_LEVEL_WIDTH-1:0] result_fifo_level;
    logic result_pop;
    logic [RESULT_LEVEL_WIDTH:0] effective_result_level;
    logic [RESULT_LEVEL_WIDTH:0] reserved_result_slots;
    logic final_can_issue;
    logic run_complete;
    logic final_complete;

    assign run_reset = (state_q == ST_RUN_RESET);
    assign layer_start_ready_o = (state_q == ST_IDLE) && activation_loaded_o;
    assign busy_o = (state_q != ST_IDLE);
    assign run_phase_o = (state_q == ST_RUN);

    activation_buffer_ram #(
        .IN_FEATURES (IN_FEATURES),
        .ACT_WIDTH   (ACT_WIDTH),
        .WORD_WIDTH  (32)
    ) u_activation_ram (
        .clk_i      (clk_i),
        .rst_i      (rst_i),
        .clear_i    (activation_clear_i && (state_q == ST_IDLE)),
        .wr_valid_i (activation_word_valid_i && (state_q == ST_IDLE)),
        .wr_ready_o (activation_word_ready_o),
        .wr_data_i  (activation_word_data_i),
        .loaded_o   (activation_loaded_o),
        .rd_en_i    (activation_ram_rd_en),
        .rd_addr_i  (activation_ram_rd_addr),
        .rd_valid_o (activation_ram_rd_valid),
        .rd_data_o  (activation_ram_rd_data)
    );

    assign activation_prefetch_start = (state_q == ST_CLEAR_START);

    activation_prefetch_stream #(
        .IN_FEATURES (IN_FEATURES),
        .ACT_WIDTH   (ACT_WIDTH),
        .WORD_WIDTH  (32)
    ) u_activation_prefetch (
        .clk_i               (clk_i),
        .rst_i               (rst_i),
        .start_i             (activation_prefetch_start),
        .ram_rd_en_o         (activation_ram_rd_en),
        .ram_rd_addr_o       (activation_ram_rd_addr),
        .ram_rd_valid_i      (activation_ram_rd_valid),
        .ram_rd_data_i       (activation_ram_rd_data),
        .activation_valid_o  (activation_stream_valid),
        .activation_ready_i  (activation_stream_ready),
        .activation_data_o   (activation_stream_data),
        .done_o              ()
    );

    assign dispatcher_start = (state_q == ST_SCHED_START);

    pe_owned_word_dispatcher #(
        .NUM_PE        (NUM_PE),
        .IN_FEATURES   (IN_FEATURES),
        .OUT_FEATURES  (OUT_FEATURES),
        .ACT_WIDTH     (ACT_WIDTH),
        .DDR_WORD_BITS (DDR_WORD_BITS),
        .GROUP_WIDTH   (GROUP_WIDTH)
    ) u_dispatcher (
        .clk_i                    (clk_i),
        .rst_i                    (rst_i || run_reset),
        .start_i                  (dispatcher_start),
        .activation_valid_i       (activation_stream_valid),
        .activation_ready_o       (activation_stream_ready),
        .activation_data_i        (activation_stream_data),
        .weight_valid_i           (weight_valid_i),
        .weight_ready_o           (weight_ready_o),
        .weight_data_i            (weight_data_i),
        .pe_entry_ready_i         (pe_entry_ready),
        .pe_entry_valid_o         (pe_entry_valid),
        .pe_activation_o          (pe_entry_activation),
        .pe_key_o                 (pe_entry_key),
        .pe_local_group_o         (pe_entry_local_group),
        .all_inputs_dispatched_o  (dispatcher_all_inputs_dispatched),
        .busy_o                   (),
        .all_active_lanes_ready_o (dispatcher_all_active_ready),
        .active_lane_mask_o       (dispatcher_active_lane_mask),
        .dispatch_fire_o          (dispatcher_fire)
    );

    genvar p;
    generate
        for (p = 0; p < NUM_PE; p = p + 1) begin : g_pe
            pe_owned_key_engine #(
                .PE_ID             (p),
                .NUM_PE            (NUM_PE),
                .OUT_FEATURES      (OUT_FEATURES),
                .ACT_WIDTH         (ACT_WIDTH),
                .ACC_WIDTH         (ACC_WIDTH),
                .GROUP_WIDTH       (GROUP_WIDTH),
                .LOCAL_ROW_WIDTH   (LOCAL_ROW_WIDTH),
                .KEY_FIFO_DEPTH    (KEY_FIFO_DEPTH),
                .DECODE_FIFO_DEPTH (DECODE_FIFO_DEPTH),
                .LUT_INIT_FILE     (LUT_INIT_FILE)
            ) u_pe (
                .clk_i                  (clk_i),
                .rst_i                  (rst_i || run_reset),
                .entry_valid_i          (pe_entry_valid[p]),
                .entry_ready_o          (pe_entry_ready[p]),
                .entry_activation_i     (pe_entry_activation),
                .entry_local_group_i    (pe_entry_local_group),
                .entry_key_i            (pe_entry_key[p*8 +: 8]),
                .product_valid_o        (pe_product_valid[p]),
                .product_ready_i        (pe_product_ready[p]),
                .product_row_o          (pe_product_row[p*LOCAL_ROW_WIDTH +: LOCAL_ROW_WIDTH]),
                .product_data_o         (pe_product_data[p*ACC_WIDTH +: ACC_WIDTH]),
                .idle_o                 (pe_idle[p]),
                .error_invalid_key_o    (pe_error_invalid_key[p]),
                .decode_entry_fire_o    (pe_decode_entry_fire[p]),
                .zero_group_fire_o      (pe_zero_group_fire[p]),
                .nonzero_group_fire_o   (pe_nonzero_group_fire[p]),
                .product_fire_o         (pe_product_fire[p]),
                .source_backpressure_o  (pe_source_backpressure[p])
            );
        end
    endgenerate

    assign error_invalid_key_o = |pe_error_invalid_key;

    assign pending_clear_start = (state_q == ST_CLEAR_START);

    pe_owned_private_accumulator #(
        .NUM_PE          (NUM_PE),
        .DATA_WIDTH      (ACC_WIDTH),
        .LOCAL_ROWS      (LOCAL_ROWS),
        .LOCAL_ROW_WIDTH (LOCAL_ROW_WIDTH),
        .FIFO_DEPTH      (PRIVATE_BANK_FIFO_DEPTH),
        .PE_SEL_WIDTH    (PE_SEL_WIDTH)
    ) u_pending (
        .clk_i                 (clk_i),
        .rst_i                 (rst_i || run_reset),
        .clear_start_i         (pending_clear_start),
        .clear_done_o          (pending_clear_done),
        .product_valid_i       (pe_product_valid),
        .product_ready_o       (pe_product_ready),
        .product_row_i         (pe_product_row),
        .product_data_i        (pe_product_data),
        .scan_valid_i          (pending_scan_valid),
        .scan_pop_i            (pending_scan_pop),
        .scan_pe_i             (pending_scan_pe),
        .scan_row_i            (pending_scan_row),
        .scan_data_o           (pending_scan_data),
        .all_fifos_empty_o     (pending_all_fifos_empty)
    );

    always_ff @(posedge clk_i) begin
        if (rst_i || run_reset)
            pending_clear_seen_q <= 1'b0;
        else if (pending_clear_done)
            pending_clear_seen_q <= 1'b1;
    end

    // Sequential global-output scan without division/modulo hardware.
    assign result_pop = result_fifo_out_valid && result_fifo_out_ready;

    always_comb begin
        effective_result_level = {1'b0, result_fifo_level};
        if (result_pop)
            effective_result_level = effective_result_level - 1'b1;
        reserved_result_slots = effective_result_level + final_inflight_valid_q;
        final_can_issue = (reserved_result_slots < FINAL_RESULT_FIFO_DEPTH);
    end

    assign final_issue =
        (state_q == ST_FINAL_DRAIN) &&
        (final_issue_count_q < OUT_FEATURES) &&
        final_can_issue;

    assign pending_scan_valid = final_issue;
    assign pending_scan_pop   = final_issue;
    assign pending_scan_pe    = final_scan_pe_q;
    assign pending_scan_row   =
        (final_scan_local_group_q * 5) + final_scan_coord_q;

    always_ff @(posedge clk_i) begin
        if (rst_i || run_reset || (state_q != ST_FINAL_DRAIN)) begin
            final_issue_count_q       <= '0;
            final_scan_pe_q           <= '0;
            final_scan_local_group_q  <= '0;
            final_scan_coord_q        <= '0;
            final_inflight_valid_q    <= 1'b0;
            final_inflight_addr_q     <= '0;
        end else begin
            final_inflight_valid_q <= final_issue;
            if (final_issue) begin
                final_inflight_addr_q <= final_issue_count_q[ADDR_WIDTH-1:0];
                final_issue_count_q <= final_issue_count_q + 1'b1;

                if (final_scan_coord_q == 4) begin
                    final_scan_coord_q <= '0;
                    if (final_scan_pe_q == NUM_PE-1) begin
                        final_scan_pe_q <= '0;
                        final_scan_local_group_q <=
                            final_scan_local_group_q + 1'b1;
                    end else begin
                        final_scan_pe_q <= final_scan_pe_q + 1'b1;
                    end
                end else begin
                    final_scan_coord_q <= final_scan_coord_q + 1'b1;
                end
            end
        end
    end

    assign result_fifo_in_valid = final_inflight_valid_q;
    assign result_fifo_in_data = {final_inflight_addr_q, pending_scan_data};

    rv_fifo #(
        .DATA_WIDTH (RESULT_PAYLOAD_WIDTH),
        .DEPTH      (FINAL_RESULT_FIFO_DEPTH)
    ) u_final_result_fifo (
        .clk_i       (clk_i),
        .rst_i       (rst_i || run_reset),
        .in_valid_i  (result_fifo_in_valid),
        .in_ready_o  (result_fifo_in_ready),
        .in_data_i   (result_fifo_in_data),
        .out_valid_o (result_fifo_out_valid),
        .out_ready_i (result_fifo_out_ready),
        .out_data_o  (result_fifo_out_data),
        .level_o     (result_fifo_level)
    );

    assign result_fifo_out_ready =
        output_ready_i && (state_q == ST_FINAL_DRAIN);
    assign output_valid_o =
        result_fifo_out_valid && (state_q == ST_FINAL_DRAIN);
    assign output_index_o =
        result_fifo_out_data[RESULT_PAYLOAD_WIDTH-1 -: ADDR_WIDTH];
    assign output_data_o =
        $signed(result_fifo_out_data[ACC_WIDTH-1:0]);

    assign run_complete =
        dispatcher_all_inputs_dispatched &&
        (&pe_idle) &&
        pending_all_fifos_empty;

    assign final_complete =
        (state_q == ST_FINAL_DRAIN) &&
        (final_issue_count_q == OUT_FEATURES) &&
        !final_inflight_valid_q &&
        (result_fifo_level == 0);

    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            state_q      <= ST_IDLE;
            layer_done_o <= 1'b0;
        end else begin
            layer_done_o <= 1'b0;
            case (state_q)
                ST_IDLE: begin
                    if (layer_start_i && layer_start_ready_o)
                        state_q <= ST_RUN_RESET;
                end
                ST_RUN_RESET:   state_q <= ST_CLEAR_START;
                ST_CLEAR_START: state_q <= ST_CLEAR_WAIT;
                ST_CLEAR_WAIT: begin
                    if (pending_clear_seen_q || pending_clear_done)
                        state_q <= ST_SCHED_START;
                end
                ST_SCHED_START: state_q <= ST_RUN;
                ST_RUN: begin
                    if (run_complete)
                        state_q <= ST_PIPE_DRAIN;
                end
                ST_PIPE_DRAIN: state_q <= ST_FINAL_DRAIN;
                ST_FINAL_DRAIN: begin
                    if (final_complete) begin
                        layer_done_o <= 1'b1;
                        state_q <= ST_IDLE;
                    end
                end
                default: state_q <= ST_IDLE;
            endcase
        end
    end

`ifndef SYNTHESIS
    initial begin
        if (NUM_PE < KEYS_PER_WORD || (NUM_PE % KEYS_PER_WORD) != 0)
            $fatal(1, "NUM_PE must be a multiple of DDR_WORD_BITS/8");
        if (!(NUM_PE == 32 || NUM_PE == 64 || NUM_PE == 128))
            $fatal(1, "evaluated scalable PE-owned modes are PE32/64/128");
        if (LUT_IMPL != 0)
            $fatal(1, "PE-owned v1 currently supports LUT_IMPL=0 only");
    end
`endif
endmodule
