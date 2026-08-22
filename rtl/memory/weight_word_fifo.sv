`timescale 1ns/1ps

// 256-bit weight-word FIFO for the current shared-partial-sum accelerator.
//
// The read side uses a request/response contract:
//   pop_req_i && pop_accepted_o  : one word is consumed
//   pop_valid_o                  : pulses one cycle later
//   pop_data_o                   : the consumed word
//
// This one-cycle response matches emif_weight_stream_to_rv.sv and permits one
// accepted request per cycle after the pipeline is filled.
module weight_word_fifo #(
    parameter integer DATA_WIDTH  = 256,
    parameter integer DEPTH       = 64,
    parameter integer COUNT_WIDTH = $clog2(DEPTH + 1)
) (
    input  logic                   clk_i,
    input  logic                   reset_n_i,
    input  logic                   flush_i,

    input  logic                   push_valid_i,
    output logic                   push_ready_o,
    input  logic [DATA_WIDTH-1:0]  push_data_i,

    input  logic                   pop_req_i,
    output logic                   pop_accepted_o,
    output logic                   pop_valid_o,
    output logic [DATA_WIDTH-1:0]  pop_data_o,

    output logic [COUNT_WIDTH-1:0] level_o,
    output logic [COUNT_WIDTH-1:0] free_words_o
);

    localparam integer PTR_WIDTH = (DEPTH <= 1) ? 1 : $clog2(DEPTH);
    localparam logic [COUNT_WIDTH-1:0] DEPTH_VALUE = DEPTH;

    // A synchronous read style is used so the FIFO can map to embedded RAM.
    (* ramstyle = "M20K" *) logic [DATA_WIDTH-1:0] mem [0:DEPTH-1];

    logic [PTR_WIDTH-1:0]   write_ptr_q;
    logic [PTR_WIDTH-1:0]   read_ptr_q;
    logic [COUNT_WIDTH-1:0] level_q;

    logic push_fire;
    logic pop_fire;

    assign level_o      = level_q;
    assign free_words_o = DEPTH_VALUE - level_q;

    // Deliberately do not accept a write while full, even if a read is also
    // requested. This avoids same-address read-during-write ambiguity in a
    // completely full circular buffer. The refill controller reserves free
    // capacity before issuing each AXI burst, so this does not reduce the
    // intended steady-state throughput.
    assign push_ready_o   = (level_q < DEPTH);
    assign pop_accepted_o = pop_req_i && (level_q != 0);

    assign push_fire = push_valid_i && push_ready_o;
    assign pop_fire  = pop_accepted_o;

    always_ff @(posedge clk_i or negedge reset_n_i) begin
        if (!reset_n_i) begin
            write_ptr_q <= '0;
            read_ptr_q  <= '0;
            level_q     <= '0;
            pop_valid_o <= 1'b0;
            pop_data_o  <= '0;
        end else if (flush_i) begin
            write_ptr_q <= '0;
            read_ptr_q  <= '0;
            level_q     <= '0;
            pop_valid_o <= 1'b0;
            pop_data_o  <= '0;
        end else begin
            pop_valid_o <= pop_fire;

            if (push_fire) begin
                mem[write_ptr_q] <= push_data_i;
                if (write_ptr_q == DEPTH-1)
                    write_ptr_q <= '0;
                else
                    write_ptr_q <= write_ptr_q + 1'b1;
            end

            if (pop_fire) begin
                pop_data_o <= mem[read_ptr_q];
                if (read_ptr_q == DEPTH-1)
                    read_ptr_q <= '0;
                else
                    read_ptr_q <= read_ptr_q + 1'b1;
            end

            case ({push_fire, pop_fire})
                2'b10: level_q <= level_q + 1'b1;
                2'b01: level_q <= level_q - 1'b1;
                default: level_q <= level_q;
            endcase
        end
    end

    initial begin
        if (DATA_WIDTH < 1)
            $fatal(1, "weight_word_fifo: DATA_WIDTH must be >= 1");
        if (DEPTH < 2)
            $fatal(1, "weight_word_fifo: DEPTH must be >= 2");
        if (COUNT_WIDTH < $clog2(DEPTH + 1))
            $fatal(1, "weight_word_fifo: COUNT_WIDTH is too small");
    end

endmodule
