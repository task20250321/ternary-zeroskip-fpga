`timescale 1ns/1ps

module activation_buffer_ram #(
    parameter integer IN_FEATURES = 2560,
    parameter integer ACT_WIDTH   = 8,
    parameter integer WORD_WIDTH  = 32,
    parameter integer LANES       = WORD_WIDTH / ACT_WIDTH,
    parameter integer WORDS       = (IN_FEATURES + LANES - 1) / LANES,
    parameter integer ADDR_WIDTH  = (WORDS <= 1) ? 1 : $clog2(WORDS),
    parameter integer COUNT_WIDTH = $clog2(WORDS + 1)
) (
    input  logic                  clk_i,
    input  logic                  rst_i,
    input  logic                  clear_i,

    // Sequential packed-word upload port.  The JTAG endpoint writes exactly
    // one 32-bit word for four int8 activations.
    input  logic                  wr_valid_i,
    output logic                  wr_ready_o,
    input  logic [WORD_WIDTH-1:0] wr_data_i,
    output logic                  loaded_o,

    // Independent synchronous read port used by the prefetcher.
    input  logic                  rd_en_i,
    input  logic [ADDR_WIDTH-1:0] rd_addr_i,
    output logic                  rd_valid_o,
    output logic [WORD_WIDTH-1:0] rd_data_o
);

    (* ramstyle = "M20K", ram_style = "M20K" *)
    logic [WORD_WIDTH-1:0] mem [0:WORDS-1];

    logic [COUNT_WIDTH-1:0] wr_count_q;
    wire wr_fire = wr_valid_i && wr_ready_o;

    assign wr_ready_o = (wr_count_q < WORDS);
    assign loaded_o   = (wr_count_q == WORDS);

    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            wr_count_q <= '0;
            rd_valid_o <= 1'b0;
            rd_data_o  <= '0;
        end else begin
            rd_valid_o <= rd_en_i;

            if (clear_i) begin
                // Contents need not be physically cleared.  A new upload
                // overwrites all logical activation words before start.
                wr_count_q <= '0;
            end else if (wr_fire) begin
                mem[wr_count_q[ADDR_WIDTH-1:0]] <= wr_data_i;
                wr_count_q <= wr_count_q + 1'b1;
            end

            if (rd_en_i)
                rd_data_o <= mem[rd_addr_i];
        end
    end

    initial begin
        if (WORD_WIDTH != 32)
            $fatal(1, "activation_buffer_ram currently requires WORD_WIDTH=32");
        if (ACT_WIDTH != 8)
            $fatal(1, "activation_buffer_ram currently requires ACT_WIDTH=8");
        if ((WORD_WIDTH % ACT_WIDTH) != 0)
            $fatal(1, "WORD_WIDTH must be divisible by ACT_WIDTH");
    end

endmodule
