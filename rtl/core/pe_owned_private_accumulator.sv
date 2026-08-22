`timescale 1ns/1ps

// One independent pending_sum_bank per PE.  There is no arbitration network:
// PE p writes only private bank p.
module pe_owned_private_accumulator #(
    parameter integer NUM_PE           = 32,
    parameter integer DATA_WIDTH       = 21,
    parameter integer LOCAL_ROWS       = 80,
    parameter integer LOCAL_ROW_WIDTH  = (LOCAL_ROWS <= 1) ? 1 : $clog2(LOCAL_ROWS),
    parameter integer FIFO_DEPTH       = 8,
    parameter integer PE_SEL_WIDTH     = (NUM_PE <= 1) ? 1 : $clog2(NUM_PE)
) (
    input  logic                                clk_i,
    input  logic                                rst_i,

    input  logic                                clear_start_i,
    output logic                                clear_done_o,

    input  logic [NUM_PE-1:0]                   product_valid_i,
    output logic [NUM_PE-1:0]                   product_ready_o,
    input  logic [NUM_PE*LOCAL_ROW_WIDTH-1:0]   product_row_i,
    input  logic [NUM_PE*DATA_WIDTH-1:0]        product_data_i,

    input  logic                                scan_valid_i,
    input  logic                                scan_pop_i,
    input  logic [PE_SEL_WIDTH-1:0]             scan_pe_i,
    input  logic [LOCAL_ROW_WIDTH-1:0]          scan_row_i,
    output logic signed [DATA_WIDTH-1:0]        scan_data_o,

    output logic                                all_fifos_empty_o
);
    logic [NUM_PE-1:0] clear_done;
    logic [NUM_PE-1:0] fifo_empty;
    logic [NUM_PE*DATA_WIDTH-1:0] scan_data_flat;
    logic [PE_SEL_WIDTH-1:0] scan_pe_q;
    logic scan_valid_q;

    genvar p;
    generate
        for (p = 0; p < NUM_PE; p = p + 1) begin : g_private_bank
            pending_sum_bank #(
                .DATA_WIDTH (DATA_WIDTH),
                .ROWS       (LOCAL_ROWS),
                .ROW_WIDTH  (LOCAL_ROW_WIDTH),
                .FIFO_DEPTH (FIFO_DEPTH)
            ) u_bank (
                .clk_i         (clk_i),
                .rst_i         (rst_i),
                .clear_start_i (clear_start_i),
                .clear_busy_o  (),
                .clear_done_o  (clear_done[p]),
                .req_valid_i   (product_valid_i[p]),
                .req_ready_o   (product_ready_o[p]),
                .req_row_i     (product_row_i[p*LOCAL_ROW_WIDTH +: LOCAL_ROW_WIDTH]),
                .req_data_i    (product_data_i[p*DATA_WIDTH +: DATA_WIDTH]),
                .scan_valid_i  (scan_valid_i && (scan_pe_i == p[PE_SEL_WIDTH-1:0])),
                .scan_pop_i    (scan_pop_i && (scan_pe_i == p[PE_SEL_WIDTH-1:0])),
                .scan_row_i    (scan_row_i),
                .scan_data_o   (scan_data_flat[p*DATA_WIDTH +: DATA_WIDTH]),
                .fifo_empty_o  (fifo_empty[p])
            );
        end
    endgenerate

    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            scan_valid_q <= 1'b0;
            scan_pe_q    <= '0;
        end else begin
            scan_valid_q <= scan_valid_i;
            if (scan_valid_i)
                scan_pe_q <= scan_pe_i;
        end
    end

    always_comb begin
        scan_data_o = '0;
        if (scan_valid_q) begin
            for (integer k = 0; k < NUM_PE; k = k + 1) begin
                if (scan_pe_q == k[PE_SEL_WIDTH-1:0])
                    scan_data_o =
                        $signed(scan_data_flat[k*DATA_WIDTH +: DATA_WIDTH]);
            end
        end
    end

    assign clear_done_o = &clear_done;
    assign all_fifos_empty_o = &fifo_empty;
endmodule
