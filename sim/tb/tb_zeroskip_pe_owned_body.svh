// Copyright 2026 Yu Inoue
// SPDX-License-Identifier: Apache-2.0

localparam integer NUM_PE             = `ZS_NUM_PE;
localparam integer NUM_BANKS          = `ZS_NUM_BANKS;
localparam integer IN_FEATURES        = `ZS_IN_FEATURES;
localparam integer OUT_FEATURES       = `ZS_OUT_FEATURES;
localparam integer LUT_IMPL           = `ZS_LUT_IMPL;
localparam integer ACC_WIDTH          = `ZS_ACC_WIDTH;
localparam integer TOTAL_WEIGHT_WORDS = `ZS_TOTAL_WEIGHT_WORDS;
localparam integer ACT_WORDS          = (IN_FEATURES + 3) / 4;
localparam integer ADDR_WIDTH =
    (OUT_FEATURES <= 1) ? 1 : $clog2(OUT_FEATURES);
localparam integer TOTAL_GROUPS = (OUT_FEATURES + 4) / 5;
localparam integer KEYS_PER_WEIGHT_WORD = 32;
localparam integer WEIGHT_WORDS_PER_INPUT =
    (TOTAL_GROUPS + KEYS_PER_WEIGHT_WORD - 1) / KEYS_PER_WEIGHT_WORD;
localparam integer LOCAL_GROUPS_PER_PE =
    (TOTAL_GROUPS + NUM_PE - 1) / NUM_PE;
localparam integer LOCAL_ROWS = LOCAL_GROUPS_PER_PE * 5;

logic clk;
logic rst;
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
logic output_valid;
logic output_ready;
logic [ADDR_WIDTH-1:0] output_index;
logic signed [ACC_WIDTH-1:0] output_data;
logic layer_done;
logic invalid_key;
logic adapter_overflow;

logic [31:0] activation_words [0:ACT_WORDS-1];
logic [255:0] weight_words [0:TOTAL_WEIGHT_WORDS-1];
logic signed [ACC_WIDTH-1:0] expected [0:OUT_FEATURES-1];

integer act_word_i;
integer req_i;
integer out_count;
integer errors;
integer layer_cycles;
integer core_run_cycles;
integer output_fd;
integer mem_fd;
integer perf_fd;
integer bank_fd [0:NUM_PE-1];
integer bank_dump_p;
integer bank_id;
string bank_path;
logic layer_started_q;
logic source_fire;

longint unsigned perf_dispatch_fire_cycles;
longint unsigned perf_dispatch_blocked_cycles;
longint unsigned perf_products_accepted_total;
longint unsigned perf_bank_backpressure_pe_cycles;
longint unsigned perf_cycles_with_bank_backpressure;
longint unsigned perf_source_backpressure_pe_cycles;
longint unsigned perf_cycles_with_source_backpressure;
longint unsigned perf_decode_entries_total;
longint unsigned perf_zero_groups_total;
longint unsigned perf_nonzero_groups_total;
longint unsigned pe_products_accepted [0:NUM_PE-1];
longint unsigned pe_decode_entries     [0:NUM_PE-1];
longint unsigned pe_zero_groups        [0:NUM_PE-1];
longint unsigned pe_nonzero_groups     [0:NUM_PE-1];
longint unsigned pe_bank_backpressure  [0:NUM_PE-1];
longint unsigned pe_source_backpressure[0:NUM_PE-1];

string case_dir;
string output_txt;
string output_mem;
string report_txt;
string perf_report_txt;
string power_vcd_file;

ternary_zeroskip_pe_owned_emif_wrapper #(
    .NUM_PE               (NUM_PE),
    .IN_FEATURES          (IN_FEATURES),
    .OUT_FEATURES         (OUT_FEATURES),
    .ACT_WIDTH            (8),
    .ACC_WIDTH            (ACC_WIDTH),
    .DDR_WORD_BITS        (256),
    .LUT_IMPL             (LUT_IMPL),
    .LUT_INIT_FILE        ("rtl/lut/trit5_lut.mem"),
    .NUM_PENDING_BANKS    (NUM_BANKS),
    .PE_OUTPUT_FIFO_DEPTH (2),
    .BANK_FIFO_DEPTH      (8),
    .ROUTER_GROUP_SIZE    (4),
    .CLUSTER_SIZE         (4),
    .KEY_FIFO_DEPTH       (8),
    .DECODE_FIFO_DEPTH    (4),
    .PRIVATE_BANK_FIFO_DEPTH (2),
    .ADAPTER_FIFO_DEPTH   (4),
    .ADDR_WIDTH           (ADDR_WIDTH)
) u_accelerator_wrapper (
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
    .error_invalid_key_o             (invalid_key),
    .error_weight_adapter_overflow_o (adapter_overflow)
);

always #5 clk = ~clk;
assign weight_available = (req_i < TOTAL_WEIGHT_WORDS);
assign source_fire = weight_req && weight_available;
assign weight_req_accepted = source_fire;

always_ff @(posedge clk) begin
    if (rst) begin
        weight_valid <= 1'b0;
        weight_data  <= '0;
        req_i        <= 0;
    end else begin
        weight_valid <= source_fire;
        if (source_fire) begin
            weight_data <= weight_words[req_i];
            req_i <= req_i + 1;
        end
    end
end

always_ff @(posedge clk) begin
    if (rst) begin
        layer_cycles    <= 0;
        core_run_cycles <= 0;
        layer_started_q <= 1'b0;
    end else begin
        if (layer_start && layer_start_ready)
            layer_started_q <= 1'b1;
        if (layer_started_q && !layer_done)
            layer_cycles <= layer_cycles + 1;
        if (layer_started_q && run_phase)
            core_run_cycles <= core_run_cycles + 1;
        if (layer_done)
            layer_started_q <= 1'b0;
    end
end

integer bp_count;
integer src_bp_count;
integer product_count;
integer decode_count;
integer zero_count;
integer nz_count;

always_ff @(posedge clk) begin
    if (rst || !run_phase) begin
        if (rst) begin
            perf_dispatch_fire_cycles <= 0;
            perf_dispatch_blocked_cycles <= 0;
            perf_products_accepted_total <= 0;
            perf_bank_backpressure_pe_cycles <= 0;
            perf_cycles_with_bank_backpressure <= 0;
            perf_source_backpressure_pe_cycles <= 0;
            perf_cycles_with_source_backpressure <= 0;
            perf_decode_entries_total <= 0;
            perf_zero_groups_total <= 0;
            perf_nonzero_groups_total <= 0;
            for (int perf_p_mon=0; perf_p_mon<NUM_PE; perf_p_mon=perf_p_mon+1) begin
                pe_products_accepted[perf_p_mon] <= 0;
                pe_decode_entries[perf_p_mon] <= 0;
                pe_zero_groups[perf_p_mon] <= 0;
                pe_nonzero_groups[perf_p_mon] <= 0;
                pe_bank_backpressure[perf_p_mon] <= 0;
                pe_source_backpressure[perf_p_mon] <= 0;
            end
        end
    end else begin
        bp_count = 0;
        src_bp_count = 0;
        product_count = 0;
        decode_count = 0;
        zero_count = 0;
        nz_count = 0;

        if (u_accelerator_wrapper.u_core.dispatcher_fire)
            perf_dispatch_fire_cycles <= perf_dispatch_fire_cycles + 1;
        if (u_accelerator_wrapper.u_core.u_dispatcher.weight_valid_i &&
            u_accelerator_wrapper.u_core.u_dispatcher.activation_valid_i &&
            !u_accelerator_wrapper.u_core.dispatcher_all_active_ready)
            perf_dispatch_blocked_cycles <= perf_dispatch_blocked_cycles + 1;

        for (int perf_p_mon=0; perf_p_mon<NUM_PE; perf_p_mon=perf_p_mon+1) begin
            if (u_accelerator_wrapper.u_core.pe_product_valid[perf_p_mon] &&
                !u_accelerator_wrapper.u_core.pe_product_ready[perf_p_mon]) begin
                bp_count = bp_count + 1;
                pe_bank_backpressure[perf_p_mon] <= pe_bank_backpressure[perf_p_mon] + 1;
            end
            if (u_accelerator_wrapper.u_core.pe_source_backpressure[perf_p_mon]) begin
                src_bp_count = src_bp_count + 1;
                pe_source_backpressure[perf_p_mon] <= pe_source_backpressure[perf_p_mon] + 1;
            end
            if (u_accelerator_wrapper.u_core.pe_product_fire[perf_p_mon]) begin
                product_count = product_count + 1;
                pe_products_accepted[perf_p_mon] <= pe_products_accepted[perf_p_mon] + 1;
            end
            if (u_accelerator_wrapper.u_core.pe_decode_entry_fire[perf_p_mon]) begin
                decode_count = decode_count + 1;
                pe_decode_entries[perf_p_mon] <= pe_decode_entries[perf_p_mon] + 1;
            end
            if (u_accelerator_wrapper.u_core.pe_zero_group_fire[perf_p_mon]) begin
                zero_count = zero_count + 1;
                pe_zero_groups[perf_p_mon] <= pe_zero_groups[perf_p_mon] + 1;
            end
            if (u_accelerator_wrapper.u_core.pe_nonzero_group_fire[perf_p_mon]) begin
                nz_count = nz_count + 1;
                pe_nonzero_groups[perf_p_mon] <= pe_nonzero_groups[perf_p_mon] + 1;
            end
        end

        perf_bank_backpressure_pe_cycles <=
            perf_bank_backpressure_pe_cycles + bp_count;
        perf_source_backpressure_pe_cycles <=
            perf_source_backpressure_pe_cycles + src_bp_count;
        perf_products_accepted_total <=
            perf_products_accepted_total + product_count;
        perf_decode_entries_total <= perf_decode_entries_total + decode_count;
        perf_zero_groups_total <= perf_zero_groups_total + zero_count;
        perf_nonzero_groups_total <= perf_nonzero_groups_total + nz_count;
        if (bp_count != 0)
            perf_cycles_with_bank_backpressure <=
                perf_cycles_with_bank_backpressure + 1;
        if (src_bp_count != 0)
            perf_cycles_with_source_backpressure <=
                perf_cycles_with_source_backpressure + 1;
    end
end

initial begin
    clk = 0;
    rst = 1;
    activation_clear = 0;
    activation_word_valid = 0;
    activation_word_data = 0;
    layer_start = 0;
    output_ready = 1;
    act_word_i = 0;
    out_count = 0;
    errors = 0;

    if (!$value$plusargs("CASE_DIR=%s", case_dir))
        $fatal(1, "+CASE_DIR=<prepared case directory> is required");

    $readmemh({case_dir, "/activation_words32.txt"}, activation_words);
    $readmemh({case_dir, "/weight_stream.mem"}, weight_words);
    $readmemh({case_dir, "/expected_outputs.mem"}, expected);

    output_txt = {case_dir, "/vcs_results/vcs_outputs.txt"};
    output_mem = {case_dir, "/vcs_results/vcs_outputs.mem"};
    report_txt = {case_dir, "/vcs_results/vcs_run_report.txt"};
    perf_report_txt = {case_dir, "/vcs_results/vcs_perf_report.txt"};

    output_fd = $fopen(output_txt, "w");
    mem_fd = $fopen(output_mem, "w");
    if (output_fd == 0 || mem_fd == 0)
        $fatal(1, "cannot open VCS output files");

    for (bank_dump_p=0;
         bank_dump_p<NUM_PE;
         bank_dump_p=bank_dump_p+1) begin

        $sformat(
            bank_path,
            "%s/vcs_results/banks/bank_%03d.txt",
            case_dir,
            bank_dump_p
        );

        bank_fd[bank_dump_p] = $fopen(bank_path, "w");

        if (bank_fd[bank_dump_p] == 0)
            $fatal(1, "cannot open %s", bank_path);
    end

    repeat (10) @(posedge clk);
    rst <= 0;
    @(posedge clk);
    activation_clear <= 1;
    @(posedge clk);
    activation_clear <= 0;

    for (act_word_i=0; act_word_i<ACT_WORDS; act_word_i=act_word_i+1) begin
        activation_word_valid <= 1;
        activation_word_data <= activation_words[act_word_i];
        do @(posedge clk); while (!activation_word_ready);
    end
    activation_word_valid <= 0;
    do @(posedge clk); while (!activation_loaded);

    if ($test$plusargs("POWER_VCD")) begin
        if (!$value$plusargs("POWER_VCD_FILE=%s", power_vcd_file))
            power_vcd_file = "pe_owned_power.vcd";
        $display("[POWER] VCD = %s", power_vcd_file);
        $dumpfile(power_vcd_file);
        $dumpvars(0, u_accelerator_wrapper);
    end

    layer_start <= 1;
    do @(posedge clk); while (!layer_start_ready);
    @(posedge clk);
    layer_start <= 0;

    while (!layer_done) begin
        @(posedge clk);
        if (output_valid && output_ready) begin
            if (output_index !== out_count[ADDR_WIDTH-1:0]) begin
                $display("ERROR index expected=%0d got=%0d", out_count, output_index);
                errors = errors + 1;
            end
            if ($signed(output_data) !== $signed(expected[out_count])) begin
                $display("ERROR output[%0d] expected=%0d got=%0d",
                         out_count, $signed(expected[out_count]), $signed(output_data));
                errors = errors + 1;
            end
            $fwrite(output_fd, "%0d\t%0d\n", out_count, $signed(output_data));
            $fwrite(mem_fd, "%0h\n", output_data);

            bank_id =
                (output_index / 5) % NUM_PE;

            $fwrite(
                bank_fd[bank_id],
                "%0d\n",
                $signed(output_data)
            );
            out_count = out_count + 1;
        end
    end

    if (output_valid && output_ready && out_count < OUT_FEATURES) begin
        if (output_index !== out_count[ADDR_WIDTH-1:0]) errors = errors + 1;
        if ($signed(output_data) !== $signed(expected[out_count])) errors = errors + 1;
        $fwrite(output_fd, "%0d\t%0d\n", out_count, $signed(output_data));
        $fwrite(mem_fd, "%0h\n", output_data);
        out_count = out_count + 1;
    end
    $fclose(output_fd);
    $fclose(mem_fd);

    for (bank_dump_p=0;
         bank_dump_p<NUM_PE;
         bank_dump_p=bank_dump_p+1) begin
        $fclose(bank_fd[bank_dump_p]);
    end

    output_fd = $fopen(report_txt, "w");
    $fwrite(output_fd, "layer_cycles=%0d\n", layer_cycles);
    $fwrite(output_fd, "core_run_cycles=%0d\n", core_run_cycles);
    $fwrite(output_fd, "weight_requests=%0d\n", req_i);
    $fwrite(output_fd, "outputs=%0d\n", out_count);
    $fwrite(output_fd, "invalid_key_error=%0d\n", invalid_key);
    $fwrite(output_fd, "adapter_overflow_error=%0d\n", adapter_overflow);
    $fwrite(output_fd, "mismatches=%0d\n", errors);
    $fclose(output_fd);

    perf_fd = $fopen(perf_report_txt, "w");
    if (perf_fd == 0) $fatal(1, "cannot open performance report");
    $fwrite(perf_fd, "architecture=pe_owned_block_cyclic_scalable_v2\n");
    $fwrite(perf_fd, "num_pe=%0d\n", NUM_PE);
    $fwrite(perf_fd, "num_private_banks=%0d\n", NUM_PE);
    $fwrite(perf_fd, "words_per_input=%0d\n", WEIGHT_WORDS_PER_INPUT);
    $fwrite(perf_fd, "local_groups_per_pe=%0d\n", LOCAL_GROUPS_PER_PE);
    $fwrite(perf_fd, "local_rows_per_pe=%0d\n", LOCAL_ROWS);
    $fwrite(perf_fd, "core_run_cycles=%0d\n", core_run_cycles);
    $fwrite(perf_fd, "products_accepted_total=%0d\n", perf_products_accepted_total);
    $fwrite(perf_fd, "bank_updates_accepted=%0d\n", perf_products_accepted_total);
    $fwrite(perf_fd, "router_stall_pe_cycles=0\n");
    $fwrite(perf_fd, "router_conflict_pe_cycles=0\n");
    $fwrite(perf_fd, "cycles_with_router_stall=0\n");
    $fwrite(perf_fd, "cycles_with_router_conflict=0\n");
    $fwrite(perf_fd, "weight_wait_pe_cycles=0\n");
    $fwrite(perf_fd, "cycles_with_weight_wait=0\n");
    $fwrite(perf_fd, "scheduler_weight_starve_cycles=0\n");
    $fwrite(perf_fd, "scheduler_activation_starve_cycles=0\n");
    $fwrite(perf_fd, "scheduler_dispatch_blocked_cycles=%0d\n", perf_dispatch_blocked_cycles);
    $fwrite(perf_fd, "bank_backpressure_pe_cycles=%0d\n", perf_bank_backpressure_pe_cycles);
    $fwrite(perf_fd, "cycles_with_bank_backpressure=%0d\n", perf_cycles_with_bank_backpressure);
    $fwrite(perf_fd, "source_backpressure_pe_cycles=%0d\n", perf_source_backpressure_pe_cycles);
    $fwrite(perf_fd, "cycles_with_source_backpressure=%0d\n", perf_cycles_with_source_backpressure);
    $fwrite(perf_fd, "dispatcher_fire_cycles=%0d\n", perf_dispatch_fire_cycles);
    $fwrite(perf_fd, "dispatcher_blocked_cycles=%0d\n", perf_dispatch_blocked_cycles);
    $fwrite(perf_fd, "decode_entries_total=%0d\n", perf_decode_entries_total);
    $fwrite(perf_fd, "zero_groups_total=%0d\n", perf_zero_groups_total);
    $fwrite(perf_fd, "nonzero_groups_total=%0d\n", perf_nonzero_groups_total);
    for (int perf_p_dump=0; perf_p_dump<NUM_PE; perf_p_dump=perf_p_dump+1) begin
        $fwrite(perf_fd,
            "pe[%0d] accepted=%0d decode_entries=%0d zero_groups=%0d nonzero_groups=%0d bank_backpressure=%0d source_backpressure=%0d\n",
            perf_p_dump, pe_products_accepted[perf_p_dump], pe_decode_entries[perf_p_dump],
            pe_zero_groups[perf_p_dump], pe_nonzero_groups[perf_p_dump],
            pe_bank_backpressure[perf_p_dump], pe_source_backpressure[perf_p_dump]);
    end
    $fclose(perf_fd);

    if (req_i != TOTAL_WEIGHT_WORDS) errors = errors + 1;
    if (out_count != OUT_FEATURES) errors = errors + 1;
    if (invalid_key || adapter_overflow) errors = errors + 1;
    if (errors != 0) $fatal(1, "FAIL: %0d error(s)", errors);

    $display("PASS: outputs=%0d layer_cycles=%0d core_run_cycles=%0d",
             out_count, layer_cycles, core_run_cycles);
    $display("PERF: %s", perf_report_txt);
    $finish;
end

initial begin : progress_watchdog
    integer monitor_cycles;
    monitor_cycles = 0;
    wait (rst === 1'b0);
    forever begin
        repeat (10000) @(posedge clk);
        monitor_cycles = monitor_cycles + 10000;
        $display("[PROGRESS] cycles=%0d busy=%0b run=%0b req=%0d/%0d outputs=%0d/%0d",
                 monitor_cycles, busy, run_phase, req_i, TOTAL_WEIGHT_WORDS,
                 out_count, OUT_FEATURES);
        if (monitor_cycles >= 5000000)
            $fatal(1, "Simulation watchdog timeout");
    end
end
