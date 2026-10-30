// AXI4-Stream 32-to-64 bit Width Converter
// With latch-based clock gating for low power
// Packs two 32-bit words into one 64-bit word
// Handles backpressure via tready/tvalid handshake

module axi4s_width_conv (
    input  wire         clk,
    input  wire         rst_n,

    // Slave (Input) - 32-bit
    input  wire [31:0]  s_axis_tdata,
    input  wire         s_axis_tvalid,
    input  wire         s_axis_tlast,
    output reg          s_axis_tready,

    // Master (Output) - 64-bit
    output reg  [63:0]  m_axis_tdata,
    output reg          m_axis_tvalid,
    output reg          m_axis_tlast,
    input  wire         m_axis_tready
);

    // FSM States
    localparam IDLE  = 2'b00;
    localparam FIRST = 2'b01;  // Got first word, waiting for second
    localparam WAIT  = 2'b11;  // Output valid, waiting for downstream ready

    reg [1:0]  state;
    reg [31:0] word0;          // Store first word

    // ---------------------------------------------------------
    // Clock gate (latch-based ICG, glitch free)
    // Latch is transparent while clk is low, so the enable can
    // only change when the clock is low.
    // !rst_n keeps the clock running during reset so state
    // is never left as X.
    // ---------------------------------------------------------
    wire clk_en = s_axis_tvalid || (state != IDLE) || !rst_n;

    reg en_latched;
    always @(*) begin
        if (!clk)
            en_latched = clk_en;
    end

    wire gated_clk = clk & en_latched;

    // ---------------------------------------------------------
    // FSM
    // ---------------------------------------------------------
    always @(posedge gated_clk or negedge rst_n) begin
        if (!rst_n) begin
            state         <= IDLE;
            word0         <= 32'b0;
            s_axis_tready <= 1'b1;
            m_axis_tdata  <= 64'b0;
            m_axis_tvalid <= 1'b0;
            m_axis_tlast  <= 1'b0;
        end else begin
            case (state)

                // IDLE: wait for first word
                IDLE: begin
                    m_axis_tvalid <= 1'b0;
                    s_axis_tready <= 1'b1;
                    if (s_axis_tvalid && s_axis_tready) begin
                        word0 <= s_axis_tdata;
                        if (s_axis_tlast) begin
                            // Odd packet: only 1 word, upper half = 0
                            m_axis_tdata  <= {32'b0, s_axis_tdata};
                            m_axis_tvalid <= 1'b1;
                            m_axis_tlast  <= 1'b1;
                            s_axis_tready <= 1'b0;
                            state         <= WAIT;
                        end else begin
                            state <= FIRST;
                        end
                    end
                end

                // FIRST: got word0, capture word1
                FIRST: begin
                    s_axis_tready <= 1'b1;
                    m_axis_tvalid <= 1'b0;
                    if (s_axis_tvalid && s_axis_tready) begin
                        m_axis_tdata  <= {s_axis_tdata, word0};
                        m_axis_tvalid <= 1'b1;
                        m_axis_tlast  <= s_axis_tlast;
                        s_axis_tready <= 1'b0;
                        state         <= WAIT;
                    end
                end

                // WAIT: output valid, hold until downstream accepts
                WAIT: begin
                    s_axis_tready <= 1'b0;
                    if (m_axis_tready && m_axis_tvalid) begin
                        m_axis_tvalid <= 1'b0;
                        s_axis_tready <= 1'b1;
                        state         <= IDLE;
                    end
                end

                default: state <= IDLE;

            endcase
        end
    end

endmodule