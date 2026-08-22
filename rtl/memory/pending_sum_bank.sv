`timescale 1ns/1ps

// Pending-sum bank backed by a synchronous M20K RAM.
//
// - pending_mem is a synchronous simple-dual-port M20K.
// - One accumulated update per cycle is supported after pipeline fill.
// - Consecutive same-row updates use explicit forwarding.
// - The RAM array has no reset; clear_start_i writes zero to every row.
// - scan_data_o corresponds to the scan request from one clock earlier.
// - External module ports are unchanged.

module pending_sum_bank #(
    parameter integer DATA_WIDTH = 20,
    parameter integer ROWS       = 40,
    parameter integer ROW_WIDTH  = (ROWS <= 1) ? 1 : $clog2(ROWS),
    parameter integer FIFO_DEPTH = 8
) (
    input  logic                         clk_i,
    input  logic                         rst_i,

    input  logic                         clear_start_i,
    output logic                         clear_busy_o,
    output logic                         clear_done_o,

    input  logic                         req_valid_i,
    output logic                         req_ready_o,
    input  logic [ROW_WIDTH-1:0]         req_row_i,
    input  logic signed [DATA_WIDTH-1:0] req_data_i,

    input  logic                         scan_valid_i,
    input  logic                         scan_pop_i,
    input  logic [ROW_WIDTH-1:0]         scan_row_i,
    output logic signed [DATA_WIDTH-1:0] scan_data_o,

    output logic                         fifo_empty_o
);

    localparam integer PAYLOAD_WIDTH = ROW_WIDTH + DATA_WIDTH;

    logic [PAYLOAD_WIDTH-1:0] fifo_in_data;
    logic [PAYLOAD_WIDTH-1:0] fifo_out_data;
    logic                     fifo_out_valid;
    logic                     fifo_out_ready;
    logic [$clog2(FIFO_DEPTH+1)-1:0] fifo_level;

    logic [ROW_WIDTH-1:0]         update_issue_row;
    logic signed [DATA_WIDTH-1:0] update_issue_data;
    logic                         update_issue;

    assign fifo_in_data = {req_row_i, req_data_i};

    rv_fifo #(
        .DATA_WIDTH (PAYLOAD_WIDTH),
        .DEPTH      (FIFO_DEPTH)
    ) u_fifo (
        .clk_i       (clk_i),
        .rst_i       (rst_i),
        .in_valid_i  (req_valid_i),
        .in_ready_o  (req_ready_o),
        .in_data_i   (fifo_in_data),
        .out_valid_o (fifo_out_valid),
        .out_ready_i (fifo_out_ready),
        .out_data_o  (fifo_out_data),
        .level_o     (fifo_level)
    );

    assign update_issue_row =
        fifo_out_data[PAYLOAD_WIDTH-1 -: ROW_WIDTH];
    assign update_issue_data =
        $signed(fifo_out_data[DATA_WIDTH-1:0]);

    assign fifo_out_ready =
        !clear_busy_o &&
        !clear_start_i &&
        !scan_valid_i;

    assign update_issue = fifo_out_valid && fifo_out_ready;

    // Keep reset logic off this array so Quartus can infer embedded RAM.
    (* ramstyle = "M20K" *)
    logic signed [DATA_WIDTH-1:0] pending_mem [0:ROWS-1];

    logic                         ram_rd_en;
    logic [ROW_WIDTH-1:0]         ram_rd_addr;
    logic signed [DATA_WIDTH-1:0] ram_rd_data_q;

    logic                         ram_wr_en;
    logic [ROW_WIDTH-1:0]         ram_wr_addr;
    logic signed [DATA_WIDTH-1:0] ram_wr_data;

    logic                         update_pipe_valid_q;
    logic [ROW_WIDTH-1:0]         update_pipe_row_q;
    logic signed [DATA_WIDTH-1:0] update_pipe_data_q;

    logic                         update_pipe_forward_q;
    logic signed [DATA_WIDTH-1:0] update_pipe_forward_base_q;

    logic signed [DATA_WIDTH-1:0] update_base;
    logic signed [DATA_WIDTH-1:0] update_result;

    logic [ROW_WIDTH-1:0] clear_row_q;

    logic                  scan_clear_valid_q;
    logic [ROW_WIDTH-1:0]  scan_clear_row_q;

    assign update_base =
        update_pipe_forward_q ?
        update_pipe_forward_base_q :
        ram_rd_data_q;

    assign update_result =
        $signed(update_base) + $signed(update_pipe_data_q);

    // One-cycle synchronous scan response.
    assign scan_data_o = ram_rd_data_q;

    always_comb begin
        ram_rd_en   = 1'b0;
        ram_rd_addr = '0;

        if (scan_valid_i && !clear_busy_o) begin
            ram_rd_en   = 1'b1;
            ram_rd_addr = scan_row_i;
        end else if (update_issue) begin
            ram_rd_en   = 1'b1;
            ram_rd_addr = update_issue_row;
        end
    end

    always_comb begin
        ram_wr_en   = 1'b0;
        ram_wr_addr = '0;
        ram_wr_data = '0;

        if (clear_busy_o) begin
            ram_wr_en   = 1'b1;
            ram_wr_addr = clear_row_q;
            ram_wr_data = '0;
        end else if (update_pipe_valid_q) begin
            ram_wr_en   = 1'b1;
            ram_wr_addr = update_pipe_row_q;
            ram_wr_data = update_result;
        end else if (scan_clear_valid_q) begin
            ram_wr_en   = 1'b1;
            ram_wr_addr = scan_clear_row_q;
            ram_wr_data = '0;
        end
    end

    // Single inferred RAM access process: synchronous read + independent write.
    always_ff @(posedge clk_i) begin
        if (ram_rd_en)
            ram_rd_data_q <= pending_mem[ram_rd_addr];

        if (ram_wr_en)
            pending_mem[ram_wr_addr] <= ram_wr_data;
    end

    // Do not declare the bank empty while the last popped FIFO request is still
    // waiting for its M20K writeback.
    assign fifo_empty_o =
        (fifo_level == 0) &&
        !update_pipe_valid_q;

    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            clear_busy_o               <= 1'b0;
            clear_done_o               <= 1'b0;
            clear_row_q                <= '0;

            update_pipe_valid_q        <= 1'b0;
            update_pipe_row_q          <= '0;
            update_pipe_data_q         <= '0;
            update_pipe_forward_q      <= 1'b0;
            update_pipe_forward_base_q <= '0;

            scan_clear_valid_q         <= 1'b0;
            scan_clear_row_q           <= '0;
        end else begin
            clear_done_o <= 1'b0;

            if (clear_start_i && !clear_busy_o) begin
                clear_busy_o        <= 1'b1;
                clear_row_q         <= '0;
                update_pipe_valid_q <= 1'b0;
                scan_clear_valid_q  <= 1'b0;
            end else if (clear_busy_o) begin
                if (clear_row_q == ROWS-1) begin
                    clear_busy_o <= 1'b0;
                    clear_done_o <= 1'b1;
                    clear_row_q  <= '0;
                end else begin
                    clear_row_q <= clear_row_q + 1'b1;
                end

                update_pipe_valid_q <= 1'b0;
                scan_clear_valid_q  <= 1'b0;
            end else begin
                // Next FIFO request enters the synchronous read/modify/write
                // pipeline. The previous pipeline entry writes back this cycle.
                update_pipe_valid_q <= update_issue;

                if (update_issue) begin
                    update_pipe_row_q  <= update_issue_row;
                    update_pipe_data_q <= update_issue_data;

                    // Same-cycle read/write to the same row is bypassed.
                    if (update_pipe_valid_q &&
                        (update_issue_row == update_pipe_row_q)) begin
                        update_pipe_forward_q      <= 1'b1;
                        update_pipe_forward_base_q <= update_result;
                    end else begin
                        update_pipe_forward_q      <= 1'b0;
                        update_pipe_forward_base_q <= '0;
                    end
                end else begin
                    update_pipe_forward_q <= 1'b0;
                end

                // Preserve destructive scan/pop semantics.
                scan_clear_valid_q <= scan_valid_i && scan_pop_i;
                if (scan_valid_i && scan_pop_i)
                    scan_clear_row_q <= scan_row_i;
            end
        end
    end

`ifndef SYNTHESIS
    initial begin
        if (ROWS < 1)
            $fatal(1, "pending_sum_bank ROWS must be >= 1");
        if (DATA_WIDTH < 1)
            $fatal(1, "pending_sum_bank DATA_WIDTH must be >= 1");
        if (FIFO_DEPTH < 1)
            $fatal(1, "pending_sum_bank FIFO_DEPTH must be >= 1");
    end
`endif

endmodule
