`timescale 1ns/1ps
`include "zeroskip_active_case.svh"

module tb_dense_owned_case;
    localparam integer NUM_PE       = `ZS_NUM_PE;
    localparam integer IN_FEATURES  = `ZS_IN_FEATURES;
    localparam integer OUT_FEATURES = `ZS_OUT_FEATURES;
    localparam integer ACC_WIDTH    = `ZS_ACC_WIDTH;
    localparam integer TOTAL_WORDS  = `ZS_TOTAL_WEIGHT_WORDS;
    localparam integer ADDR_WIDTH   = (OUT_FEATURES <= 1) ? 1 : $clog2(OUT_FEATURES);
    localparam integer ACT_WORDS    = (IN_FEATURES + 3) / 4;

    logic clk = 1'b0;
    logic rst = 1'b1;
    always #5 clk = ~clk;

    logic activation_clear;
    logic activation_word_valid;
    logic activation_word_ready;
    logic [31:0] activation_word_data;
    logic activation_loaded;
    logic layer_start;
    logic layer_start_ready;
    logic busy;
    logic run_phase;

    logic weight_available;
    logic weight_req;
    logic weight_req_accepted;
    logic [255:0] weight_data;
    logic weight_valid;
    logic source_fire;

    logic output_valid;
    logic output_ready;
    logic [ADDR_WIDTH-1:0] output_index;
    logic signed [ACC_WIDTH-1:0] output_data;
    logic layer_done;
    logic invalid_key_error;
    logic adapter_overflow_error;

    logic [255:0] weight_mem [0:TOTAL_WORDS-1];
    logic [31:0] activation_mem [0:ACT_WORDS-1];
    logic signed [ACC_WIDTH-1:0] expected_mem [0:OUT_FEATURES-1];

    integer weight_index;
    integer activation_index;
    integer outputs_seen;
    integer mismatch_count;
    integer layer_cycles;
    integer core_run_cycles;
    integer output_fd;
    integer report_fd;
    integer perf_fd;
    integer p;
    longint unsigned perf_dispatch_fire_cycles;
    longint unsigned perf_dispatch_blocked_cycles;
    longint unsigned perf_products_accepted_total;
    longint unsigned perf_bank_backpressure_pe_cycles;

    string case_dir;
    string weight_file;
    string activation_file;
    string expected_file;
    string output_file;
    string report_file;
    string perf_file;

    ternary_dense_owned_emif_wrapper #(
        .NUM_PE                  (NUM_PE),
        .IN_FEATURES             (IN_FEATURES),
        .OUT_FEATURES            (OUT_FEATURES),
        .ACT_WIDTH               (8),
        .ACC_WIDTH               (ACC_WIDTH),
        .DDR_WORD_BITS           (256),
        .LUT_IMPL                (0),
        .LUT_INIT_FILE           ("rtl/lut/trit5_lut.mem"),
        .NUM_PENDING_BANKS       (`ZS_NUM_BANKS),
        .KEY_FIFO_DEPTH          (8),
        .DECODE_FIFO_DEPTH       (4),
        .PRIVATE_BANK_FIFO_DEPTH (2),
        .ADAPTER_FIFO_DEPTH      (4),
        .ADDR_WIDTH              (ADDR_WIDTH)
    ) dut (
        .clk_i                           (clk),
        .rst_i                           (rst),
        .activation_clear_i              (activation_clear),
        .activation_word_valid_i         (activation_word_valid),
        .activation_word_ready_o         (activation_word_ready),
        .activation_word_data_i          (activation_word_data),
        .activation_loaded_o             (activation_loaded),
        .layer_start_i                   (layer_start),
        .layer_start_ready_o             (layer_start_ready),
        .busy_o                          (busy),
        .run_phase_o                     (run_phase),
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

    assign weight_available = (weight_index < TOTAL_WORDS);

    // Request is accepted in the request cycle.
    // The corresponding response arrives one cycle later.
    assign source_fire = weight_req && weight_available;
    assign weight_req_accepted = source_fire;

    assign output_ready = 1'b1;

    integer fire_count_comb;
    integer bp_count_comb;
    always_comb begin
        fire_count_comb = 0;
        bp_count_comb = 0;
        for (int pc = 0; pc < NUM_PE; pc = pc + 1) begin
            if (dut.u_core.pe_product_valid[pc] && dut.u_core.pe_product_ready[pc])
                fire_count_comb = fire_count_comb + 1;
            if (dut.u_core.pe_product_valid[pc] && !dut.u_core.pe_product_ready[pc])
                bp_count_comb = bp_count_comb + 1;
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            weight_valid <= 1'b0;
            weight_data <= '0;
            weight_index <= 0;
        end else begin
            // One-cycle request -> response latency.
            weight_valid <= source_fire;

            if (source_fire) begin
                weight_data <= weight_mem[weight_index];
                weight_index <= weight_index + 1;
            end
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            layer_cycles <= 0;
            core_run_cycles <= 0;
            perf_dispatch_fire_cycles <= 0;
            perf_dispatch_blocked_cycles <= 0;
            perf_products_accepted_total <= 0;
            perf_bank_backpressure_pe_cycles <= 0;
        end else begin
            if (busy)
                layer_cycles <= layer_cycles + 1;
            if (run_phase)
                core_run_cycles <= core_run_cycles + 1;

            if (run_phase) begin
                if (dut.u_core.dispatcher_fire)
                    perf_dispatch_fire_cycles <= perf_dispatch_fire_cycles + 1;
                if (dut.stream_valid && !dut.stream_ready)
                    perf_dispatch_blocked_cycles <= perf_dispatch_blocked_cycles + 1;

                perf_products_accepted_total <=
                    perf_products_accepted_total + fire_count_comb;
                perf_bank_backpressure_pe_cycles <=
                    perf_bank_backpressure_pe_cycles + bp_count_comb;
            end
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            outputs_seen   <= 0;
            mismatch_count <= 0;
        end else if (output_valid && output_ready) begin
            $fdisplay(output_fd, "%0d\t%0d", output_index, $signed(output_data));
            outputs_seen <= outputs_seen + 1;
            if ($signed(output_data) !== $signed(expected_mem[output_index])) begin
                mismatch_count <= mismatch_count + 1;
                $display("MISMATCH index=%0d got=%0d expected=%0d",
                         output_index, $signed(output_data),
                         $signed(expected_mem[output_index]));
            end
        end
    end

    initial begin
        activation_clear = 1'b0;
        activation_word_valid = 1'b0;
        activation_word_data = '0;
        layer_start = 1'b0;

        if (!$value$plusargs("CASE_DIR=%s", case_dir))
            $fatal(1, "+CASE_DIR=<path> is required");

        weight_file = {case_dir, "/weight_stream.mem"};
        activation_file = {case_dir, "/activation_words32.txt"};
        expected_file = {case_dir, "/expected_outputs.mem"};
        output_file = {case_dir, "/vcs_results/vcs_outputs.txt"};
        report_file = {case_dir, "/vcs_results/vcs_run_report.txt"};
        perf_file = {case_dir, "/vcs_results/vcs_perf_report.txt"};

        $readmemh(weight_file, weight_mem);
        $readmemh(activation_file, activation_mem);
        $readmemh(expected_file, expected_mem);

        output_fd = $fopen(output_file, "w");
        if (!output_fd) $fatal(1, "cannot open %s", output_file);

        repeat (8) @(posedge clk);
        rst <= 1'b0;

        @(posedge clk);
        activation_clear <= 1'b1;
        @(posedge clk);
        activation_clear <= 1'b0;

        activation_index = 0;
        while (activation_index < ACT_WORDS) begin
            @(negedge clk);
            activation_word_valid = 1'b1;
            activation_word_data = activation_mem[activation_index];
            @(posedge clk);
            if (activation_word_ready)
                activation_index = activation_index + 1;
        end
        @(negedge clk);
        activation_word_valid = 1'b0;

        while (!activation_loaded) @(posedge clk);
        while (!layer_start_ready) @(posedge clk);

        @(negedge clk);
        layer_start = 1'b1;
        @(negedge clk);
        layer_start = 1'b0;

        fork
            begin : watchdog
                repeat (2000000) @(posedge clk);

                $display("\n[DENSE-OWNED DEBUG] watchdog timeout");

                $display(
                    "state=%0d busy=%0b run=%0b layer_cycles=%0d core_cycles=%0d outputs=%0d",
                    dut.u_core.state_q,
                    busy,
                    run_phase,
                    layer_cycles,
                    core_run_cycles,
                    outputs_seen
                );

                $display(
                    "weight_index=%0d/%0d req=%0b response_valid=%0b stream_valid=%0b stream_ready=%0b",
                    weight_index,
                    TOTAL_WORDS,
                    weight_req,
                    weight_valid,
                    dut.stream_valid,
                    dut.stream_ready
                );

                $display(
                    "dispatcher: active=%0b input=%0d/%0d word=%0d fire=%0b all_dispatched=%0b",
                    dut.u_core.u_dispatcher.active_q,
                    dut.u_core.u_dispatcher.input_count_q,
                    IN_FEATURES,
                    dut.u_core.u_dispatcher.word_q,
                    dut.u_core.dispatcher_fire,
                    dut.u_core.dispatcher_all_inputs_dispatched
                );

                $display(
                    "activation: loaded=%0b stream_valid=%0b stream_ready=%0b",
                    activation_loaded,
                    dut.u_core.activation_stream_valid,
                    dut.u_core.activation_stream_ready
                );

                $display(
                    "pe_idle=%h",
                    dut.u_core.pe_idle
                );

                $display(
                    "pe_entry_ready=%h",
                    dut.u_core.pe_entry_ready
                );

                $display(
                    "pe_product_valid=%h",
                    dut.u_core.pe_product_valid
                );

                $display(
                    "pe_product_ready=%h",
                    dut.u_core.pe_product_ready
                );

                $display(
                    "pending: clear_done=%0b clear_seen=%0b fifos_empty=%0b",
                    dut.u_core.pending_clear_done,
                    dut.u_core.pending_clear_seen_q,
                    dut.u_core.pending_all_fifos_empty
                );

                $display(
                    "PE0: source_level=%0d decoded_level=%0d coord=%0d product=%0b/%0b row=%0d",
                    dut.u_core.g_pe[0].u_pe.source_level,
                    dut.u_core.g_pe[0].u_pe.decoded_fifo_level,
                    dut.u_core.g_pe[0].u_pe.emit_coord_q,
                    dut.u_core.g_pe[0].u_pe.product_valid_o,
                    dut.u_core.g_pe[0].u_pe.product_ready_i,
                    dut.u_core.g_pe[0].u_pe.product_row_o
                );

                $display(
                    "bank0: fifo_level=%0d update_pipe=%0b clear_busy=%0b",
                    dut.u_core.u_pending.g_private_bank[0].u_bank.fifo_level,
                    dut.u_core.u_pending.g_private_bank[0].u_bank.update_pipe_valid_q,
                    dut.u_core.u_pending.g_private_bank[0].u_bank.clear_busy_o
                );

                $display(
                    "final: issue_count=%0d inflight=%0b result_level=%0d",
                    dut.u_core.final_issue_count_q,
                    dut.u_core.final_inflight_valid_q,
                    dut.u_core.result_fifo_level
                );

                $fatal(1, "dense-owned watchdog timeout");
            end
            begin : wait_done
                while (!layer_done) @(posedge clk);
                disable watchdog;
            end
        join

        repeat (4) @(posedge clk);

        report_fd = $fopen(report_file, "w");
        if (!report_fd) $fatal(1, "cannot open %s", report_file);
        $fdisplay(report_fd, "layer_cycles=%0d", layer_cycles);
        $fdisplay(report_fd, "core_run_cycles=%0d", core_run_cycles);
        $fdisplay(report_fd, "weight_requests=%0d", weight_index);
        $fdisplay(report_fd, "outputs=%0d", outputs_seen);
        $fdisplay(report_fd, "invalid_key_error=%0d", invalid_key_error);
        $fdisplay(report_fd, "adapter_overflow_error=%0d", adapter_overflow_error);
        $fdisplay(report_fd, "mismatches=%0d", mismatch_count);
        $fclose(report_fd);

        perf_fd = $fopen(perf_file, "w");
        if (!perf_fd) $fatal(1, "cannot open %s", perf_file);
        $fdisplay(perf_fd, "architecture=dense_pe_owned_v1");
        $fdisplay(perf_fd, "num_pe=%0d", NUM_PE);
        $fdisplay(perf_fd, "core_run_cycles=%0d", core_run_cycles);
        $fdisplay(perf_fd, "dispatcher_fire_cycles=%0d", perf_dispatch_fire_cycles);
        $fdisplay(perf_fd, "dispatcher_blocked_cycles=%0d", perf_dispatch_blocked_cycles);
        $fdisplay(perf_fd, "products_accepted_total=%0d", perf_products_accepted_total);
        $fdisplay(perf_fd, "bank_backpressure_pe_cycles=%0d", perf_bank_backpressure_pe_cycles);
        $fclose(perf_fd);
        $fclose(output_fd);

        if (weight_index != TOTAL_WORDS)
            $fatal(1, "weight count mismatch: got %0d expected %0d", weight_index, TOTAL_WORDS);
        if (outputs_seen != OUT_FEATURES)
            $fatal(1, "output count mismatch: got %0d expected %0d", outputs_seen, OUT_FEATURES);
        if (mismatch_count != 0)
            $fatal(1, "%0d output mismatches", mismatch_count);
        if (invalid_key_error || adapter_overflow_error)
            $fatal(1, "dense-owned error flags invalid=%0d overflow=%0d",
                   invalid_key_error, adapter_overflow_error);

        $display("PASS dense-owned: PE=%0d IN=%0d OUT=%0d core=%0d layer=%0d",
                 NUM_PE, IN_FEATURES, OUT_FEATURES, core_run_cycles, layer_cycles);
        $finish;
    end
endmodule
