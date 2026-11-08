// Self-checking bench for pmod_stream. No processor. Checks idle drive,
// per-word timing on play_clk, capture, idle restore, abort, back-to-back
// plays, and a zero-length fault.

`timescale 1ns / 1ps

module tb_pmod_stream;
    localparam [15:0] REG_CTRL     = 16'h0000;
    localparam [15:0] REG_STATUS   = 16'h0004;
    localparam [15:0] REG_LENGTH   = 16'h0008;
    localparam [15:0] REG_CAPCOUNT = 16'h000C;
    localparam [15:0] REG_IDLE_OUT = 16'h0010;
    localparam [15:0] REG_IDLE_OE  = 16'h0014;
    localparam [15:0] REG_PIN_IN   = 16'h0018;
    localparam [15:0] TX_BASE      = 16'h1000;
    localparam [15:0] RX_BASE      = 16'h9000;

    reg         axi_clk = 1'b0;
    reg         play_clk = 1'b0;
    reg         axi_rstn = 1'b0;
    reg         play_rstn = 1'b0;

    reg  [15:0] awaddr;
    reg         awvalid;
    reg  [31:0] wdata;
    reg  [3:0]  wstrb;
    reg         wvalid;
    wire        awready;
    wire        wready;
    wire [1:0]  bresp;
    wire        bvalid;
    reg         bready;
    reg  [15:0] araddr;
    reg         arvalid;
    wire        arready;
    wire [31:0] rdata;
    wire [1:0]  rresp;
    wire        rvalid;
    reg         rready;

    wire [7:0]  pmod;
    wire        irq;
    wire        status_led;

    integer errors;

    pmod_stream dut (
        .s_axi_aclk    (axi_clk),
        .s_axi_aresetn (axi_rstn),
        .s_axi_awaddr  (awaddr),
        .s_axi_awvalid (awvalid),
        .s_axi_awready (awready),
        .s_axi_wdata   (wdata),
        .s_axi_wstrb   (wstrb),
        .s_axi_wvalid  (wvalid),
        .s_axi_wready  (wready),
        .s_axi_bresp   (bresp),
        .s_axi_bvalid  (bvalid),
        .s_axi_bready  (bready),
        .s_axi_araddr  (araddr),
        .s_axi_arvalid (arvalid),
        .s_axi_arready (arready),
        .s_axi_rdata   (rdata),
        .s_axi_rresp   (rresp),
        .s_axi_rvalid  (rvalid),
        .s_axi_rready  (rready),
        .play_clk      (play_clk),
        .play_aresetn  (play_rstn),
        .pmod_io       (pmod),
        .irq           (irq),
        .status_led    (status_led)
    );

    // When the player releases a pin, present the word's data bit so capture
    // of an input samples a known value without fighting a driven pin.
    genvar gi;
    generate
        for (gi = 0; gi < 8; gi = gi + 1) begin : g_pull
            assign pmod[gi] = (dut.pin_oe_r[gi] === 1'b0) ? dut.pin_dout_r[gi] : 1'bz;
        end
    endgenerate

    always #5.0 axi_clk = ~axi_clk;
    always #2.5 play_clk = ~play_clk;

    task automatic axi_write(input [15:0] addr, input [31:0] data);
        integer guard;
        begin
            @(posedge axi_clk);
            awaddr  <= addr;
            wdata   <= data;
            wstrb   <= 4'hF;
            awvalid <= 1'b1;
            wvalid  <= 1'b1;
            guard = 0;
            do begin
                @(posedge axi_clk);
                guard = guard + 1;
                if (guard > 50) begin
                    $fatal(1, "AXI write timeout addr %h", addr);
                end
            end while (!(awvalid && wvalid && awready && wready));
            awvalid <= 1'b0;
            wvalid  <= 1'b0;
            guard = 0;
            do begin
                @(posedge axi_clk);
                guard = guard + 1;
                if (guard > 50) $fatal(1, "AXI bresp timeout");
            end while (!bvalid);
        end
    endtask

    task automatic axi_read(input [15:0] addr, output [31:0] data);
        integer guard;
        begin
            @(posedge axi_clk);
            araddr  <= addr;
            arvalid <= 1'b1;
            guard = 0;
            do begin
                @(posedge axi_clk);
                guard = guard + 1;
                if (guard > 50) $fatal(1, "AXI read addr timeout %h", addr);
            end while (!(arvalid && arready));
            arvalid <= 1'b0;
            guard = 0;
            do begin
                @(posedge axi_clk);
                guard = guard + 1;
                if (guard > 50) $fatal(1, "AXI read data timeout %h", addr);
            end while (!rvalid);
            #0.1;
            data = rdata;
        end
    endtask

    // Address and data on different cycles. This is what the MicroBlaze
    // interconnect does; a slave that only completes same-cycle beats deadlocks.
    task automatic axi_write_split(
        input [15:0] addr,
        input [31:0] data,
        input integer addr_first
    );
        integer guard;
        begin
            @(posedge axi_clk);
            awaddr <= addr;
            wdata  <= data;
            wstrb  <= 4'hF;
            if (addr_first) begin
                awvalid <= 1'b1;
                guard = 0;
                do begin
                    @(posedge axi_clk);
                    guard = guard + 1;
                    if (guard > 50) $fatal(1, "split AW timeout");
                end while (!(awvalid && awready));
                awvalid <= 1'b0;
                @(posedge axi_clk);
                wvalid <= 1'b1;
            end else begin
                wvalid <= 1'b1;
                guard = 0;
                do begin
                    @(posedge axi_clk);
                    guard = guard + 1;
                    if (guard > 50) $fatal(1, "split W timeout");
                end while (!(wvalid && wready));
                wvalid <= 1'b0;
                @(posedge axi_clk);
                awvalid <= 1'b1;
            end
            guard = 0;
            do begin
                @(posedge axi_clk);
                guard = guard + 1;
                if (guard > 50) $fatal(1, "split second beat timeout");
            end while (!((addr_first ? wvalid && wready : awvalid && awready)));
            awvalid <= 1'b0;
            wvalid  <= 1'b0;
            guard = 0;
            do begin
                @(posedge axi_clk);
                guard = guard + 1;
                if (guard > 50) $fatal(1, "split bresp timeout");
            end while (!bvalid);
        end
    endtask

    task automatic wait_status(input [31:0] mask, input [31:0] value);
        integer guard;
        reg [31:0] s;
        begin
            guard = 0;
            s = 32'h0;
            do begin
                axi_read(REG_STATUS, s);
                guard = guard + 1;
                if (guard > 200) begin
                    $fatal(1, "status timeout, got %h want mask %h == %h", s, mask, value);
                end
            end while ((s & mask) != value);
        end
    endtask

    task automatic check_words(
        input integer n,
        input logic [7:0] oev [0:31],
        input logic [7:0] doutv [0:31],
        input integer cycv [0:31]
    );
        integer pi;
        integer seen;
        integer guard;
        reg match;
        begin
            guard = 0;
            forever begin
                @(posedge play_clk);
                #0.1;
                guard = guard + 1;
                if (guard > 4000) $fatal(1, "timeout waiting for long stream");
                if (dut.pin_oe_r === oev[0] && dut.pin_dout_r === doutv[0]) break;
            end
            pi = 0;
            seen = 1;
            guard = 0;
            forever begin
                @(posedge play_clk);
                #0.1;
                guard = guard + 1;
                if (guard > 4000) $fatal(1, "timeout in long word %0d", pi);
                match = (dut.pin_oe_r === oev[pi]) && (dut.pin_dout_r === doutv[pi]);
                if (match) begin
                    seen = seen + 1;
                end else begin
                    if (seen != cycv[pi]) begin
                        $fatal(1, "word %0d held %0d cycles, want %0d (oe %h dout %h)",
                               pi, seen, cycv[pi], oev[pi], doutv[pi]);
                    end
                    pi = pi + 1;
                    if (pi == n) break;
                    if (dut.pin_oe_r !== oev[pi] || dut.pin_dout_r !== doutv[pi]) begin
                        $fatal(1, "word %0d got oe %h dout %h, want oe %h dout %h",
                               pi, dut.pin_oe_r, dut.pin_dout_r, oev[pi], doutv[pi]);
                    end
                    seen = 1;
                end
            end
        end
    endtask

    task automatic check_phases(
        input integer n,
        input logic [7:0] oev [0:7],
        input logic [7:0] doutv [0:7],
        input integer cycv [0:7]
    );
        integer pi;
        integer seen;
        integer guard;
        reg match;
        begin
            guard = 0;
            forever begin
                @(posedge play_clk);
                #0.1;
                guard = guard + 1;
                if (guard > 4000) $fatal(1, "timeout waiting for first phase");
                if (dut.pin_oe_r === oev[0] && dut.pin_dout_r === doutv[0]) break;
            end
            pi = 0;
            seen = 1;
            guard = 0;
            forever begin
                @(posedge play_clk);
                #0.1;
                guard = guard + 1;
                if (guard > 4000) $fatal(1, "timeout in phase %0d", pi);
                match = (dut.pin_oe_r === oev[pi]) && (dut.pin_dout_r === doutv[pi]);
                if (match) begin
                    seen = seen + 1;
                end else begin
                    if (seen != cycv[pi]) begin
                        $fatal(1, "phase %0d held %0d cycles, want %0d (oe %h dout %h)",
                               pi, seen, cycv[pi], oev[pi], doutv[pi]);
                    end
                    pi = pi + 1;
                    if (pi == n) break;
                    if (dut.pin_oe_r !== oev[pi] || dut.pin_dout_r !== doutv[pi]) begin
                        $fatal(1, "phase %0d got oe %h dout %h, want oe %h dout %h",
                               pi, dut.pin_oe_r, dut.pin_dout_r, oev[pi], doutv[pi]);
                    end
                    seen = 1;
                end
            end
        end
    endtask

    reg [31:0] rd;
    logic [7:0] oev [0:7];
    logic [7:0] doutv [0:7];
    integer cycv [0:7];
    integer i;

    function automatic [31:0] pack(input [7:0] oe, input [7:0] dout, input [15:0] dur);
        pack = {oe, dout, dur};
    endfunction

    initial begin
        errors  = 0;
        awaddr  = 16'h0;
        awvalid = 1'b0;
        wdata   = 32'h0;
        wstrb   = 4'h0;
        wvalid  = 1'b0;
        bready  = 1'b1;
        araddr  = 16'h0;
        arvalid = 1'b0;
        rready  = 1'b1;

        axi_rstn  = 1'b0;
        play_rstn = 1'b0;
        repeat (20) @(posedge axi_clk);
        axi_rstn  = 1'b1;
        play_rstn = 1'b1;
        repeat (30) @(posedge axi_clk);
        #0.1;
        if (dut.pin_oe_r !== 8'h00) $fatal(1, "reset did not Hi-Z the pins, oe=%h", dut.pin_oe_r);

        axi_write_split(REG_LENGTH, 32'd7, 1);
        axi_read(REG_LENGTH, rd);
        if (rd[15:0] !== 16'd7) $fatal(1, "split AW-then-W length %h", rd);
        axi_write_split(REG_LENGTH, 32'd9, 0);
        axi_read(REG_LENGTH, rd);
        if (rd[15:0] !== 16'd9) $fatal(1, "split W-then-AW length %h", rd);
        axi_write(REG_LENGTH, 32'd0);

        // Idle drive propagates into the play domain.
        axi_write(REG_IDLE_OE, 32'h0000_000F);
        axi_write(REG_IDLE_OUT, 32'h0000_0003);
        begin : wait_idle
            integer guard;
            guard = 0;
            forever begin
                @(posedge play_clk);
                #0.1;
                guard = guard + 1;
                if (dut.pin_oe_r === 8'h0F && dut.pin_dout_r === 8'h03) break;
                if (guard > 200) $fatal(1, "idle levels did not reach the pins");
            end
        end
        axi_read(REG_PIN_IN, rd);
        // PIN_IN is synchronized. Give it a few more reads.
        repeat (4) axi_read(REG_PIN_IN, rd);
        if (rd[7:0] !== 8'h03) $fatal(1, "PIN_IN %h, want 03", rd[7:0]);

        // TX window readback.
        axi_write(TX_BASE, pack(8'hFF, 8'h11, 16'd5));
        axi_read(TX_BASE, rd);
        if (rd !== pack(8'hFF, 8'h11, 16'd5)) $fatal(1, "TX readback %h", rd);

        axi_write(TX_BASE + 16'h4, pack(8'hFF, 8'h22, 16'd7));
        axi_write(TX_BASE + 16'h8, pack(8'h00, 8'h5A, 16'd6));
        axi_write(TX_BASE + 16'hC, pack(8'hF0, 8'hA5, 16'd4));
        axi_write(REG_LENGTH, 32'd4);
        axi_write(REG_CTRL, 32'h4); // irq enable

        oev[0] = 8'hFF; doutv[0] = 8'h11; cycv[0] = 5;
        oev[1] = 8'hFF; doutv[1] = 8'h22; cycv[1] = 7;
        oev[2] = 8'h00; doutv[2] = 8'h5A; cycv[2] = 6;
        oev[3] = 8'hF0; doutv[3] = 8'hA5; cycv[3] = 4;
        fork
            check_phases(4, oev, doutv, cycv);
            begin
                axi_write(REG_CTRL, 32'h5); // irq_en + start
            end
        join
        if (dut.pin_oe_r !== 8'h0F || dut.pin_dout_r !== 8'h03)
            $fatal(1, "play did not restore idle oe %h dout %h", dut.pin_oe_r, dut.pin_dout_r);

        wait_status(32'h7, 32'h2); // done, not busy, not fault
        if (irq !== 1'b1) $fatal(1, "irq did not assert");
        axi_read(REG_CAPCOUNT, rd);
        if (rd !== 32'd4) $fatal(1, "cap_count %0d, want 4", rd);

        axi_read(RX_BASE, rd);
        if (rd !== 32'hA55A_2211) $fatal(1, "capture %h, want a55a2211", rd);

        axi_write(REG_STATUS, 32'h6); // clear done and fault
        repeat (2) @(posedge axi_clk);
        #0.1;
        if (irq !== 1'b0) $fatal(1, "irq stayed high after clear");

        // Zero length is a fault and does not leave the pins busy.
        axi_write(REG_LENGTH, 32'd0);
        axi_write(REG_CTRL, 32'h5);
        wait_status(32'h6, 32'h6); // done + fault
        axi_read(REG_STATUS, rd);
        if (rd[0] !== 1'b0) $fatal(1, "busy set after zero-length play");
        axi_write(REG_STATUS, 32'h6);

        // Abort a long level and restore idle.
        axi_write(TX_BASE, pack(8'hFF, 8'h80, 16'd400));
        axi_write(REG_LENGTH, 32'd1);
        axi_write(REG_CTRL, 32'h5);
        begin : see_run
            integer guard;
            guard = 0;
            forever begin
                @(posedge play_clk);
                #0.1;
                guard = guard + 1;
                if (dut.pin_oe_r === 8'hFF && dut.pin_dout_r === 8'h80) break;
                if (guard > 2000) $fatal(1, "abort pattern never started");
            end
        end
        axi_write(REG_CTRL, 32'h6); // irq_en + abort
        begin : see_idle
            integer guard;
            guard = 0;
            forever begin
                @(posedge play_clk);
                #0.1;
                guard = guard + 1;
                if (dut.pin_oe_r === 8'h0F && dut.pin_dout_r === 8'h03) break;
                if (guard > 2000) $fatal(1, "abort did not restore idle");
            end
        end
        wait_status(32'h3, 32'h2); // done, not busy
        axi_read(REG_STATUS, rd);
        if (rd[2] !== 1'b0) $fatal(1, "abort reported fault");
        axi_write(REG_STATUS, 32'h6);

        // Back-to-back plays.
        axi_write(TX_BASE, pack(8'hFF, 8'h01, 16'd5));
        axi_write(REG_LENGTH, 32'd1);
        oev[0] = 8'hFF; doutv[0] = 8'h01; cycv[0] = 5;
        fork
            check_phases(1, oev, doutv, cycv);
            axi_write(REG_CTRL, 32'h5);
        join
        wait_status(32'h3, 32'h2);
        axi_write(REG_STATUS, 32'h6);

        axi_write(TX_BASE, pack(8'hFF, 8'h02, 16'd5));
        oev[0] = 8'hFF; doutv[0] = 8'h02; cycv[0] = 5;
        fork
            check_phases(1, oev, doutv, cycv);
            axi_write(REG_CTRL, 32'h5);
        join
        wait_status(32'h3, 32'h2);

        // Eight back-to-back 1-cycle words. This is the prefetch case that
        // used to bypass the block RAM straight into the state machine.
        for (i = 0; i < 8; i = i + 1) begin
            axi_write(TX_BASE + (i * 4), pack(8'hFF, 8'h10 + i[7:0], 16'd1));
            oev[i] = 8'hFF;
            doutv[i] = 8'h10 + i[7:0];
            cycv[i] = 1;
        end
        axi_write(REG_LENGTH, 32'd8);
        axi_write(REG_STATUS, 32'h6);
        fork
            check_phases(8, oev, doutv, cycv);
            axi_write(REG_CTRL, 32'h1);
        join
        wait_status(32'h3, 32'h2);
        axi_read(REG_STATUS, rd);
        if (rd[2] !== 1'b0) $fatal(1, "duration-1 stream faulted");

        // A full SPI byte is 18 one-tick words, and a longer run is what
        // 100 MHz playback actually asks of the prefetch queue.
        begin : dur1_long
            logic [7:0] oe_l [0:31];
            logic [7:0] dout_l [0:31];
            integer cyc_l [0:31];
            integer k;
            for (k = 0; k < 32; k = k + 1) begin
                oe_l[k] = 8'hFF;
                dout_l[k] = 8'h40 + k[7:0];
                cyc_l[k] = 1;
                axi_write(TX_BASE + (k * 4), pack(oe_l[k], dout_l[k], 16'd1));
            end
            axi_write(REG_LENGTH, 32'd32);
            axi_write(REG_STATUS, 32'h6);
            fork
                check_words(32, oe_l, dout_l, cyc_l);
                axi_write(REG_CTRL, 32'h1);
            join
            wait_status(32'h3, 32'h2);
            axi_read(REG_STATUS, rd);
            if (rd[2] !== 1'b0) $fatal(1, "long duration-1 stream faulted");
        end

        $display("tb_pmod_stream: PASS");
        $finish(0);
    end

    initial begin
        #200_000;
        $fatal(1, "simulation timeout");
    end
endmodule
