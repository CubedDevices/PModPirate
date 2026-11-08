// pmod_stream: play a run-length pin stream onto an 8-bit Pmod port.
//
// Each TX word is {oe[7:0], dout[7:0], duration[15:0]}. duration is a count of
// play_clk cycles, minimum 1. The word is driven for that many cycles. On the
// last cycle the resolved pin value is captured, one byte per word.
//
// While idle, IDLE_OE / IDLE_OUT drive the pins. Reset and the end of a play
// both return to those idle levels (reset forces Hi-Z because the idle
// registers come up zero).
//
// Register map (byte offsets):
//   0x0000 CTRL      [0] start  [1] abort  [2] irq_en
//   0x0004 STATUS    [0] busy   [1] done (W1C)  [2] fault (W1C)
//   0x0008 LENGTH    number of TX words to play
//   0x000C CAP_COUNT samples stored by the last play
//   0x0010 IDLE_OUT  idle output data
//   0x0014 IDLE_OE   idle output enable (1 = drive)
//   0x0018 PIN_IN    synchronized pin sample
//   0x1000 TX        8192 words
//   0x9000 RX        2048 packed words, sample i in byte (i % 4)

`timescale 1ns / 1ps

module pmod_stream #(
    parameter integer TX_WORDS   = 8192,
    parameter integer RX_SAMPLES = 8192
) (
    input  wire        s_axi_aclk,
    input  wire        s_axi_aresetn,
    input  wire [15:0] s_axi_awaddr,
    input  wire        s_axi_awvalid,
    output wire        s_axi_awready,
    input  wire [31:0] s_axi_wdata,
    input  wire [3:0]  s_axi_wstrb,
    input  wire        s_axi_wvalid,
    output wire        s_axi_wready,
    output wire [1:0]  s_axi_bresp,
    output wire        s_axi_bvalid,
    input  wire        s_axi_bready,
    input  wire [15:0] s_axi_araddr,
    input  wire        s_axi_arvalid,
    output wire        s_axi_arready,
    output wire [31:0] s_axi_rdata,
    output wire [1:0]  s_axi_rresp,
    output wire        s_axi_rvalid,
    input  wire        s_axi_rready,

    input  wire        play_clk,
    input  wire        play_aresetn,
    inout  wire [7:0]  pmod_io,
    output wire        irq,
    output wire        status_led
);

    localparam integer TX_AW = 13;
    localparam integer RX_W  = RX_SAMPLES / 4;

    localparam [15:0] REG_CTRL     = 16'h0000;
    localparam [15:0] REG_STATUS   = 16'h0004;
    localparam [15:0] REG_LENGTH   = 16'h0008;
    localparam [15:0] REG_CAPCOUNT = 16'h000C;
    localparam [15:0] REG_IDLE_OUT = 16'h0010;
    localparam [15:0] REG_IDLE_OE  = 16'h0014;
    localparam [15:0] REG_PIN_IN   = 16'h0018;
    localparam [15:0] TX_BASE      = 16'h1000;
    localparam [15:0] RX_BASE      = 16'h9000;
    localparam [15:0] RX_LIMIT     = 16'hB000;

    localparam [2:0] ST_IDLE   = 3'd0;
    localparam [2:0] ST_DROP   = 3'd1;
    localparam [2:0] ST_FILL   = 3'd2;
    localparam [2:0] ST_RUN    = 3'd3;
    localparam [2:0] ST_FINISH = 3'd4;

    // ------------------------------------------------------------------
    // AXI-Lite
    // ------------------------------------------------------------------
    reg        bvalid_r;
    reg        rvalid_r;
    reg [31:0] rdata_r;
    reg [1:0]  rd_wait;
    reg [15:0] rd_addr_r;
    reg        rd_is_tx;
    reg        rd_is_rx;
    reg [31:0] rd_reg_r;

    reg [15:0] length_axi;
    reg [7:0]  idle_out_axi;
    reg [7:0]  idle_oe_axi;
    reg        irq_en;
    reg        done_sticky;
    reg        fault_sticky;
    reg [15:0] cap_count_axi;
    reg        start_pulse;
    reg        abort_pulse;
    reg        start_pending;
    reg        start_send;
    reg        busy_axi;

    // Address and data are separate AXI channels. Ready stays high on only
    // one of them until that beat is captured. Asserting both readies whenever
    // a response is idle accepts an address beat that has no data yet, and the
    // master then waits forever for BVALID.
    reg        aw_hold;
    reg        w_hold;
    reg [15:0] aw_addr_r;
    reg [31:0] w_data_r;
    reg [3:0]  w_strb_r;

    assign s_axi_awready = s_axi_aresetn && !aw_hold && !bvalid_r;
    assign s_axi_wready  = s_axi_aresetn && !w_hold && !bvalid_r;
    assign s_axi_bresp   = 2'b00;
    assign s_axi_bvalid  = bvalid_r;
    assign s_axi_rresp   = 2'b00;
    assign s_axi_rvalid  = rvalid_r;
    assign s_axi_rdata   = rdata_r;
    assign s_axi_arready = s_axi_aresetn && (rd_wait == 2'd0) && !rvalid_r;

    wire aw_accept = s_axi_awvalid && s_axi_awready;
    wire w_accept  = s_axi_wvalid && s_axi_wready;
    wire wr_commit = (aw_hold || aw_accept) && (w_hold || w_accept);
    wire rd_fire = s_axi_arvalid && s_axi_arready;

    wire [15:0] wr_addr = aw_hold ? aw_addr_r : {s_axi_awaddr[15:2], 2'b00};
    wire [31:0] wr_data = w_hold ? w_data_r : s_axi_wdata;
    wire [3:0]  wr_strb = w_hold ? w_strb_r : s_axi_wstrb;
    wire [15:0] ar_addr = {s_axi_araddr[15:2], 2'b00};

    wire wr_is_tx = (wr_addr >= TX_BASE) && (wr_addr < RX_BASE);
    wire wr_is_rx = (wr_addr >= RX_BASE) && (wr_addr < RX_LIMIT);
    wire [12:0] tx_windex = (wr_addr - TX_BASE) >> 2;
    wire        tx_we = wr_commit && wr_is_tx && (tx_windex < TX_WORDS) && (wr_strb == 4'hF);

    reg  [31:0] tx_axi_rdata;
    wire [31:0] rx_axi_rdata;

    wire [7:0] pin_in_axi;
    wire       busy_play_axi;
    wire       start_rcv;
    wire       done_req;
    wire [16:0] done_payload;

    reg [25:0] heartbeat;

    (* ram_style = "block" *) reg [31:0] tx_mem [0:TX_WORDS-1];

    wire [12:0] tx_a_addr = tx_we ? tx_windex : ((rd_addr_r - TX_BASE) >> 2);
    always @(posedge s_axi_aclk) begin
        if (tx_we)
            tx_mem[tx_windex] <= wr_data;
        tx_axi_rdata <= tx_mem[tx_a_addr];
    end

    always @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            bvalid_r      <= 1'b0;
            rvalid_r      <= 1'b0;
            rdata_r       <= 32'h0;
            rd_wait       <= 2'd0;
            rd_addr_r     <= 16'h0;
            rd_is_tx      <= 1'b0;
            rd_is_rx      <= 1'b0;
            rd_reg_r      <= 32'h0;
            length_axi    <= 16'h0;
            idle_out_axi  <= 8'h0;
            idle_oe_axi   <= 8'h0;
            irq_en        <= 1'b0;
            done_sticky   <= 1'b0;
            fault_sticky  <= 1'b0;
            cap_count_axi <= 16'h0;
            start_pulse   <= 1'b0;
            abort_pulse   <= 1'b0;
            start_pending <= 1'b0;
            start_send    <= 1'b0;
            heartbeat     <= 26'h0;
            aw_hold       <= 1'b0;
            w_hold        <= 1'b0;
        end else begin
            start_pulse <= 1'b0;
            abort_pulse <= 1'b0;
            heartbeat   <= heartbeat + 26'd1;

            if (bvalid_r && s_axi_bready)
                bvalid_r <= 1'b0;
            if (wr_commit) begin
                bvalid_r <= 1'b1;
                aw_hold  <= 1'b0;
                w_hold   <= 1'b0;
                if (wr_addr == REG_CTRL) begin
                    irq_en <= wr_data[2];
                    if (wr_data[0] && !busy_axi && !start_send && !start_pending)
                        start_pending <= 1'b1;
                    else if (wr_data[0] && (busy_axi || start_send || start_pending))
                        fault_sticky <= 1'b1;
                    if (wr_data[1])
                        abort_pulse <= 1'b1;
                end else if (wr_addr == REG_STATUS) begin
                    if (wr_data[1])
                        done_sticky <= 1'b0;
                    if (wr_data[2])
                        fault_sticky <= 1'b0;
                end else if (wr_addr == REG_LENGTH) begin
                    length_axi <= wr_data[15:0];
                end else if (wr_addr == REG_IDLE_OUT) begin
                    idle_out_axi <= wr_data[7:0];
                end else if (wr_addr == REG_IDLE_OE) begin
                    idle_oe_axi <= wr_data[7:0];
                end
            end else begin
                if (aw_accept) begin
                    aw_hold   <= 1'b1;
                    aw_addr_r <= {s_axi_awaddr[15:2], 2'b00};
                end
                if (w_accept) begin
                    w_hold   <= 1'b1;
                    w_data_r <= s_axi_wdata;
                    w_strb_r <= s_axi_wstrb;
                end
            end

            if (!start_send && start_pending && !start_rcv) begin
                start_send    <= 1'b1;
                start_pending <= 1'b0;
                start_pulse   <= 1'b0;
            end else if (start_send && start_rcv) begin
                start_send <= 1'b0;
            end

            if (done_req) begin
                done_sticky   <= 1'b1;
                cap_count_axi <= {done_payload[15:0]};
                if (done_payload[16])
                    fault_sticky <= 1'b1;
            end

            if (rd_fire) begin
                rd_wait   <= 2'd2;
                rd_addr_r <= ar_addr;
                rd_is_tx  <= (ar_addr >= TX_BASE) && (ar_addr < RX_BASE);
                rd_is_rx  <= (ar_addr >= RX_BASE) && (ar_addr < RX_LIMIT);
                if (ar_addr == REG_CTRL)
                    rd_reg_r <= {29'h0, irq_en, 2'b00};
                else if (ar_addr == REG_STATUS)
                    rd_reg_r <= {29'h0, fault_sticky, done_sticky, busy_axi};
                else if (ar_addr == REG_LENGTH)
                    rd_reg_r <= {16'h0, length_axi};
                else if (ar_addr == REG_CAPCOUNT)
                    rd_reg_r <= {16'h0, cap_count_axi};
                else if (ar_addr == REG_IDLE_OUT)
                    rd_reg_r <= {24'h0, idle_out_axi};
                else if (ar_addr == REG_IDLE_OE)
                    rd_reg_r <= {24'h0, idle_oe_axi};
                else if (ar_addr == REG_PIN_IN)
                    rd_reg_r <= {24'h0, pin_in_axi};
                else
                    rd_reg_r <= 32'h0;
            end else if (rd_wait != 2'd0) begin
                rd_wait <= rd_wait - 2'd1;
                if (rd_wait == 2'd1) begin
                    rvalid_r <= 1'b1;
                    if (rd_is_tx)
                        rdata_r <= tx_axi_rdata;
                    else if (rd_is_rx)
                        rdata_r <= rx_axi_rdata;
                    else
                        rdata_r <= rd_reg_r;
                end
            end else if (rvalid_r && s_axi_rready) begin
                rvalid_r <= 1'b0;
            end
        end
    end

    // Status busy is a level. Sample the synchronizer into the status bit
    // the software polls. done/fault stay sticky across that.
    always @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn)
            busy_axi <= 1'b0;
        else
            busy_axi <= busy_play_axi;
    end

    // ------------------------------------------------------------------
    // Clock-domain crossing
    // ------------------------------------------------------------------
    wire        play_rstn;
    wire [7:0]  idle_oe_play;
    wire [7:0]  idle_out_play;
    wire        abort_play;
    wire        start_req;
    wire [15:0] start_len;
    wire        busy_play;
    wire [7:0]  pin_sync_axi_w;

    xpm_cdc_async_rst #(
        .DEST_SYNC_FF    (4),
        .INIT_SYNC_FF    (0),
        .RST_ACTIVE_HIGH (0)
    ) rst_play (
        .src_arst  (play_aresetn),
        .dest_clk  (play_clk),
        .dest_arst (play_rstn)
    );

    xpm_cdc_array_single #(
        .DEST_SYNC_FF  (3),
        .INIT_SYNC_FF  (0),
        .SIM_ASSERT_CHK(0),
        .SRC_INPUT_REG (1),
        .WIDTH         (8)
    ) cdc_idle_oe (
        .src_clk  (s_axi_aclk),
        .src_in   (idle_oe_axi),
        .dest_clk (play_clk),
        .dest_out (idle_oe_play)
    );

    xpm_cdc_array_single #(
        .DEST_SYNC_FF  (3),
        .INIT_SYNC_FF  (0),
        .SIM_ASSERT_CHK(0),
        .SRC_INPUT_REG (1),
        .WIDTH         (8)
    ) cdc_idle_out (
        .src_clk  (s_axi_aclk),
        .src_in   (idle_out_axi),
        .dest_clk (play_clk),
        .dest_out (idle_out_play)
    );

    xpm_cdc_handshake #(
        .DEST_EXT_HSK  (0),
        .DEST_SYNC_FF  (3),
        .INIT_SYNC_FF  (0),
        .SIM_ASSERT_CHK(0),
        .SRC_SYNC_FF   (3),
        .WIDTH         (16)
    ) cdc_start (
        .src_clk  (s_axi_aclk),
        .src_in   (length_axi),
        .src_send (start_send),
        .src_rcv  (start_rcv),
        .dest_clk (play_clk),
        .dest_out (start_len),
        .dest_req (start_req),
        .dest_ack (1'b0)
    );

    xpm_cdc_pulse #(
        .DEST_SYNC_FF(3),
        .INIT_SYNC_FF(0),
        .REG_OUTPUT  (1),
        .RST_USED    (1),
        .SIM_ASSERT_CHK(0)
    ) cdc_abort (
        .src_clk    (s_axi_aclk),
        .src_pulse  (abort_pulse),
        .src_rst    (~s_axi_aresetn),
        .dest_clk   (play_clk),
        .dest_rst   (~play_rstn),
        .dest_pulse (abort_play)
    );

    xpm_cdc_single #(
        .DEST_SYNC_FF (3),
        .INIT_SYNC_FF (0),
        .SIM_ASSERT_CHK(0),
        .SRC_INPUT_REG(1)
    ) cdc_busy (
        .src_clk  (play_clk),
        .src_in   (busy_play),
        .dest_clk (s_axi_aclk),
        .dest_out (busy_play_axi)
    );

    // ------------------------------------------------------------------
    // Pins
    // ------------------------------------------------------------------
    reg [7:0] pin_oe_r;
    reg [7:0] pin_dout_r;
    reg [7:0] pin_meta;
    reg [7:0] pin_sync;
    wire [7:0] pin_ibuf;

    genvar gi;
    generate
        for (gi = 0; gi < 8; gi = gi + 1) begin : g_pin
            // T=1 releases the pin. The pad input comes back on O so the
            // capture flop is not reading the inout net through the driver.
            IOBUF pin_iobuf (
                .O  (pin_ibuf[gi]),
                .IO (pmod_io[gi]),
                .I  (pin_dout_r[gi]),
                .T  (~pin_oe_r[gi])
            );
        end
    endgenerate

    always @(posedge play_clk) begin
        if (!play_rstn) begin
            pin_meta <= 8'h00;
            pin_sync <= 8'h00;
        end else begin
            pin_meta <= pin_ibuf;
            pin_sync <= pin_meta;
        end
    end

    xpm_cdc_array_single #(
        .DEST_SYNC_FF  (3),
        .INIT_SYNC_FF  (0),
        .SIM_ASSERT_CHK(0),
        .SRC_INPUT_REG (1),
        .WIDTH         (8)
    ) cdc_pin_in (
        .src_clk  (play_clk),
        .src_in   (pin_sync),
        .dest_clk (s_axi_aclk),
        .dest_out (pin_in_axi)
    );

    // ------------------------------------------------------------------
    // Capture RAM, 4 byte banks so one AXI word returns 4 samples
    // ------------------------------------------------------------------
    (* ram_style = "block" *) reg [7:0] rx0 [0:RX_W-1];
    (* ram_style = "block" *) reg [7:0] rx1 [0:RX_W-1];
    (* ram_style = "block" *) reg [7:0] rx2 [0:RX_W-1];
    (* ram_style = "block" *) reg [7:0] rx3 [0:RX_W-1];

    reg        rx_we;
    reg [12:0] rx_index;
    reg [7:0]  rx_byte;
    reg [7:0]  rx_r0, rx_r1, rx_r2, rx_r3;

    wire [10:0] rx_waddr = rx_index[12:2];
    wire [10:0] rx_raddr = ((rd_addr_r - RX_BASE) >> 2);

    always @(posedge play_clk) begin
        if (rx_we) begin
            case (rx_index[1:0])
                2'd0: rx0[rx_waddr] <= rx_byte;
                2'd1: rx1[rx_waddr] <= rx_byte;
                2'd2: rx2[rx_waddr] <= rx_byte;
                default: rx3[rx_waddr] <= rx_byte;
            endcase
        end
    end

    always @(posedge s_axi_aclk) begin
        rx_r0 <= rx0[rx_raddr];
        rx_r1 <= rx1[rx_raddr];
        rx_r2 <= rx2[rx_raddr];
        rx_r3 <= rx3[rx_raddr];
    end
    assign rx_axi_rdata = {rx_r3, rx_r2, rx_r1, rx_r0};

    // ------------------------------------------------------------------
    // Play-side TX read pipeline. rvalid/rdata correspond to the address
    // issued two play clocks earlier.
    // ------------------------------------------------------------------
    reg [12:0] issue_addr;
    reg        issue_en;
    reg [12:0] addr_d;
    reg        en_d;
    reg [31:0] play_rdata;
    reg        play_rvalid;

    always @(posedge play_clk) begin
        if (!play_rstn) begin
            addr_d      <= 13'h0;
            en_d        <= 1'b0;
            play_rdata  <= 32'h0;
            play_rvalid <= 1'b0;
        end else begin
            addr_d      <= issue_addr;
            en_d        <= issue_en;
            play_rdata  <= tx_mem[addr_d];
            play_rvalid <= en_d;
        end
    end

    // ------------------------------------------------------------------
    // Player
    // ------------------------------------------------------------------
    reg [2:0]  state;
    reg [15:0] length_p;
    reg [15:0] issued;
    reg [15:0] consumed;
    reg [15:0] samples;
    reg [15:0] hold;
    reg [3:0]  pipe_level;
    reg [2:0]  drop_left;
    reg        fault_p;
    reg        discard;
    reg        done_send;
    reg [16:0] done_bus;
    reg        start_armed;

    (* ram_style = "distributed" *) reg [31:0] q_mem [0:7];
    reg [2:0]  q_head;
    reg [2:0]  q_tail;
    reg [3:0]  q_count;
    // One word pulled out of q_mem a cycle before it is applied. The pin
    // flops then see a register, not the distributed RAM, in the same cycle
    // a new level is loaded. That path is the 200 MHz failure, and a
    // duration of 1 (SPI above 50 MHz) takes it on every clock.
    reg        pref_valid;
    reg [31:0] pref_word;
    reg        word_last;

    wire       done_rcv;

    xpm_cdc_handshake #(
        .DEST_EXT_HSK  (0),
        .DEST_SYNC_FF  (3),
        .INIT_SYNC_FF  (0),
        .SIM_ASSERT_CHK(0),
        .SRC_SYNC_FF   (3),
        .WIDTH         (17)
    ) cdc_done (
        .src_clk  (play_clk),
        .src_in   (done_bus),
        .src_send (done_send),
        .src_rcv  (done_rcv),
        .dest_clk (s_axi_aclk),
        .dest_out (done_payload),
        .dest_req (done_req),
        .dest_ack (1'b0)
    );

    assign busy_play = (state != ST_IDLE);

    integer pl_n;
    integer qc_n;
    integer head_n;
    integer tail_n;
    reg        do_issue;
    reg        bad_len;

    // Pop the queue into pref_word when playback will consume pref this
    // cycle, or when pref is empty. Duration 0 is not consumed.
    wire play_hot = (state == ST_FILL) || (state == ST_RUN);
    wire fsm_take = play_hot && pref_valid && (pref_word[15:0] != 16'h0) &&
                    !abort_play &&
                    ((state == ST_FILL) || ((hold == 16'd1) && !word_last));

    always @(posedge play_clk) begin
        if (!play_rstn) begin
            state      <= ST_IDLE;
            length_p   <= 16'h0;
            issued     <= 16'h0;
            consumed   <= 16'h0;
            samples    <= 16'h0;
            hold       <= 16'h0;
            pipe_level <= 4'h0;
            drop_left  <= 3'h0;
            fault_p    <= 1'b0;
            discard    <= 1'b0;
            done_send  <= 1'b0;
            done_bus   <= 17'h0;
            start_armed<= 1'b0;
            q_head     <= 3'h0;
            q_tail     <= 3'h0;
            q_count    <= 4'h0;
            issue_en   <= 1'b0;
            issue_addr <= 13'h0;
            pin_oe_r   <= 8'h00;
            pin_dout_r <= 8'h00;
            rx_we      <= 1'b0;
            rx_index   <= 13'h0;
            rx_byte    <= 8'h00;
            pref_valid <= 1'b0;
            pref_word  <= 32'h0;
            word_last  <= 1'b0;
        end else begin
            rx_we    <= 1'b0;
            issue_en <= 1'b0;

            pl_n = pipe_level;
            qc_n = q_count;
            head_n = q_head;
            tail_n = q_tail;

            // Pop before the push so a full queue frees a slot for the word
            // arriving from the block RAM. The queue is kept to 7 entries so
            // that read and write are never the same distributed-RAM address.
            if (play_hot && q_count > 0 && (!pref_valid || fsm_take)) begin
                pref_word  <= q_mem[q_head];
                pref_valid <= 1'b1;
                head_n = head_n + 1;
                qc_n = qc_n - 1;
            end else if (fsm_take) begin
                pref_valid <= 1'b0;
            end

            if (play_rvalid && !discard && state != ST_DROP) begin
                pl_n = pl_n - 1;
                if (qc_n < 8) begin
                    q_mem[tail_n[2:0]] <= play_rdata;
                    tail_n = tail_n + 1;
                    qc_n = qc_n + 1;
                end
            end else if (play_rvalid && (discard || state == ST_DROP)) begin
                if (pl_n > 0)
                    pl_n = pl_n - 1;
            end

            if (discard && pl_n == 0 && !play_rvalid)
                discard <= 1'b0;

            do_issue = 1'b0;

            if (done_send && done_rcv)
                done_send <= 1'b0;

            case (state)
                ST_IDLE: begin
                    pin_oe_r   <= idle_oe_play;
                    pin_dout_r <= idle_out_play;
                    if (start_req)
                        start_armed <= 1'b1;
                    if (start_armed && !discard && pipe_level == 0 && !done_send) begin
                        start_armed <= 1'b0;
                        bad_len = (start_len == 16'h0) || (start_len > TX_WORDS);
                        length_p   <= start_len;
                        issued     <= 16'h0;
                        consumed   <= 16'h0;
                        samples    <= 16'h0;
                        fault_p    <= bad_len;
                        head_n = 0;
                        tail_n = 0;
                        qc_n = 0;
                        pref_valid <= 1'b0;
                        word_last  <= 1'b0;
                        drop_left  <= 3'd3;
                        state      <= bad_len ? ST_FINISH : ST_DROP;
                    end
                end

                ST_DROP: begin
                    pin_oe_r   <= idle_oe_play;
                    pin_dout_r <= idle_out_play;
                    head_n = 0;
                    tail_n = 0;
                    qc_n = 0;
                    pref_valid <= 1'b0;
                    word_last  <= 1'b0;
                    if (drop_left == 0 && pl_n == 0)
                        state <= ST_FILL;
                    else if (drop_left != 0)
                        drop_left <= drop_left - 3'd1;
                end

                ST_FILL: begin
                    pin_oe_r   <= idle_oe_play;
                    pin_dout_r <= idle_out_play;
                    // Leave one queue slot empty so a pop and a push in the
                    // same cycle use different RAM addresses.
                    // Credit uses the registered counts so this enable does not
                    // depend on the same-cycle pop. That pop is what tracks hold.
                    do_issue = (issued < length_p) &&
                               ((q_count + pipe_level) < 7);
                    if (abort_play) begin
                        fault_p <= 1'b0;
                        state   <= ST_FINISH;
                    end else if (pref_valid) begin
                        if (pref_word[15:0] == 16'h0) begin
                            fault_p <= 1'b1;
                            state   <= ST_FINISH;
                        end else begin
                            pin_oe_r   <= pref_word[31:24];
                            pin_dout_r <= pref_word[23:16];
                            hold       <= pref_word[15:0];
                            word_last  <= (length_p == 16'd1);
                            state <= ST_RUN;
                        end
                    end
                end

                ST_RUN: begin
                    do_issue = (issued < length_p) &&
                               ((q_count + pipe_level) < 7) && !abort_play;
                    if (abort_play) begin
                        state <= ST_FINISH;
                    end else if (hold == 16'd1) begin
                        rx_we    <= 1'b1;
                        rx_index <= consumed[12:0];
                        rx_byte  <= pin_sync;
                        samples  <= consumed + 16'd1;
                        if (word_last) begin
                            pin_oe_r   <= idle_oe_play;
                            pin_dout_r <= idle_out_play;
                            state <= ST_FINISH;
                        end else if (pref_valid) begin
                            if (pref_word[15:0] == 16'h0) begin
                                fault_p <= 1'b1;
                                state   <= ST_FINISH;
                            end else begin
                                pin_oe_r   <= pref_word[31:24];
                                pin_dout_r <= pref_word[23:16];
                                hold       <= pref_word[15:0];
                                consumed   <= consumed + 16'd1;
                                word_last  <= (consumed + 16'd2 == length_p);
                            end
                        end else begin
                            fault_p <= 1'b1;
                            state   <= ST_FINISH;
                        end
                    end else begin
                        hold <= hold - 16'd1;
                    end
                end

                ST_FINISH: begin
                    pin_oe_r   <= idle_oe_play;
                    pin_dout_r <= idle_out_play;
                    discard    <= 1'b1;
                    head_n = 0;
                    tail_n = 0;
                    qc_n = 0;
                    pref_valid <= 1'b0;
                    word_last  <= 1'b0;
                    if (!done_send) begin
                        done_bus  <= {fault_p, samples};
                        done_send <= 1'b1;
                        state     <= ST_IDLE;
                    end
                end

                default: state <= ST_IDLE;
            endcase

            if (do_issue) begin
                issue_en   <= 1'b1;
                issue_addr <= issued[12:0];
                issued     <= issued + 16'd1;
                pl_n = pl_n + 1;
            end

            pipe_level <= pl_n[3:0];
            q_count    <= qc_n[3:0];
            q_head     <= head_n[2:0];
            q_tail     <= tail_n[2:0];
        end
    end

    assign irq = irq_en & (done_sticky | fault_sticky);
    assign status_led = busy_axi | heartbeat[25];

endmodule
