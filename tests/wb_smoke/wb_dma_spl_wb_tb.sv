// ======================================================================
// Wishbone-level smoke test for the wb_dma_spl wrapper.
//
// Drives the DMA through ACTUAL Wishbone pins (no direct class-model access):
//   - an external Wishbone initiator (u_host) programs the channel registers via
//     the DUT's WB0 slave port;
//   - two Wishbone memory slaves (u_mem0/u_mem1) back the DUT's WB0/WB1 master
//     ports (the data movers).
//
// It programs channel 0 for a normal-mode (software) 8-word block copy from
// 0x1000 to 0x2000 through IF0 (WB0 master), polls the channel CSR DONE bit
// through the register file, and checks the destination memory.
//
// Run:  dfm run fw-wb-dma.wb-smoke     (expect: [wb_dma_spl_wb] PASS)
// ======================================================================
module wb_dma_spl_wb_tb;
    import fw_hdl_pkg::*;
    import fw_std_pkg::*;
    import fw_proto_wb_pkg::*;

    localparam logic [31:0] SRC = 32'h0000_1000;
    localparam logic [31:0] DST = 32'h0000_2000;
    localparam int          NW  = 8;

    // Channel-0 register offsets (rf decode: 0x20 base, 0x20 stride/channel).
    localparam logic [31:0] CH0_CSR  = 32'h20;
    localparam logic [31:0] CH0_SZ   = 32'h24;
    localparam logic [31:0] CH0_ADR0 = 32'h28;   // source
    localparam logic [31:0] CH0_ADR1 = 32'h30;   // destination

    // ---- a Wishbone memory model (backs a master port) -----------------------
    class wb_mem implements wb_proto_if #(32, 32);
        logic [31:0] mem [logic [31:0]];
        virtual task access(
                input  [31:0] adr, input [31:0] dat_w, input [3:0] sel, input we,
                output [31:0] dat_r, output err);
            if (we) mem[adr] = dat_w;
            else    dat_r = mem.exists(adr) ? mem[adr] : 32'h0;
            err = 1'b0;
        endtask
    endclass

    // ---- clock / reset -------------------------------------------------------
    logic clk = 1'b0;
    logic rst = 1'b1;
    always #5ns clk = ~clk;

    // ---- three Wishbone buses ------------------------------------------------
    // Host -> DUT WB0 slave.
    wire [31:0] h_dat_w, h_dat_r, h_adr;  wire [3:0] h_sel;
    wire        h_we, h_cyc, h_stb, h_ack, h_err;
    // DUT WB0 master -> mem0.
    wire [31:0] m0_adr, m0_dat_w, m0_dat_r;  wire [3:0] m0_sel;
    wire        m0_we, m0_cyc, m0_stb, m0_ack, m0_err;
    // DUT WB1 master -> mem1.
    wire [31:0] m1_adr, m1_dat_w, m1_dat_r;  wire [3:0] m1_sel;
    wire        m1_we, m1_cyc, m1_stb, m1_ack, m1_err;

    wire        inta, intb;
    wire [3:0]  dma_ack;

    // ---- DUT -----------------------------------------------------------------
    wb_dma_spl #(.ch_count(4)) dut (
        .clk_i(clk), .rst_i(rst),
        // WB0 slave (host)
        .wb0s_data_i(h_dat_w), .wb0s_data_o(h_dat_r), .wb0_addr_i(h_adr),
        .wb0_sel_i(h_sel), .wb0_we_i(h_we), .wb0_cyc_i(h_cyc), .wb0_stb_i(h_stb),
        .wb0_ack_o(h_ack), .wb0_err_o(h_err), .wb0_rty_o(),
        // WB0 master (IF0)
        .wb0m_data_i(m0_dat_r), .wb0m_data_o(m0_dat_w), .wb0_addr_o(m0_adr),
        .wb0_sel_o(m0_sel), .wb0_we_o(m0_we), .wb0_cyc_o(m0_cyc), .wb0_stb_o(m0_stb),
        .wb0_ack_i(m0_ack), .wb0_err_i(m0_err), .wb0_rty_i(1'b0),
        // WB1 slave (unused)
        .wb1s_data_i(32'h0), .wb1s_data_o(), .wb1_addr_i(32'h0),
        .wb1_sel_i(4'h0), .wb1_we_i(1'b0), .wb1_cyc_i(1'b0), .wb1_stb_i(1'b0),
        .wb1_ack_o(), .wb1_err_o(), .wb1_rty_o(),
        // WB1 master (IF1)
        .wb1m_data_i(m1_dat_r), .wb1m_data_o(m1_dat_w), .wb1_addr_o(m1_adr),
        .wb1_sel_o(m1_sel), .wb1_we_o(m1_we), .wb1_cyc_o(m1_cyc), .wb1_stb_o(m1_stb),
        .wb1_ack_i(m1_ack), .wb1_err_i(m1_err), .wb1_rty_i(1'b0),
        // DMA handshake (stubbed)
        .dma_req_i(4'h0), .dma_ack_o(dma_ack), .dma_nd_i(4'h0), .dma_rest_i(4'h0),
        // interrupts
        .inta_o(inta), .intb_o(intb));

    // ---- external transactors ------------------------------------------------
    wb_initiator_xtor u_host (
        .clock(clk), .reset(rst),
        .adr(h_adr), .dat_w(h_dat_w), .dat_r(h_dat_r),
        .cyc(h_cyc), .stb(h_stb), .sel(h_sel), .we(h_we),
        .ack(h_ack), .err(h_err));

    wb_target_xtor u_mem0 (
        .clock(clk), .reset(rst),
        .adr(m0_adr), .dat_w(m0_dat_w), .dat_r(m0_dat_r),
        .cyc(m0_cyc), .stb(m0_stb), .sel(m0_sel), .we(m0_we),
        .ack(m0_ack), .err(m0_err));

    wb_target_xtor u_mem1 (
        .clock(clk), .reset(rst),
        .adr(m1_adr), .dat_w(m1_dat_w), .dat_r(m1_dat_r),
        .cyc(m1_cyc), .stb(m1_stb), .sel(m1_sel), .we(m1_we),
        .ack(m1_ack), .err(m1_err));

    // ---- stimulus ------------------------------------------------------------
    wb_mem                             mem0, mem1;
    wb_initiator_xtor_bridge #(32, 32) hbr;
    wb_target_xtor_bridge    #(32, 32) m0br, m1br;

    task automatic wr(input logic [31:0] adr, input logic [31:0] dat);
        logic [31:0] dr; logic err;
        hbr.access(adr, dat, 4'hf, 1'b1, dr, err);
    endtask
    task automatic rd(input logic [31:0] adr, output logic [31:0] dat);
        logic err;
        hbr.access(adr, 32'h0, 4'hf, 1'b0, dat, err);
    endtask

    initial begin
        automatic int errors = 0;
        automatic logic [31:0] csr, got, exp;

        // Build bridges; back the two master memories.
        mem0 = new(); mem1 = new();
        hbr  = new(u_host.u_if);
        m0br = new(u_mem0.u_if, mem0);
        m1br = new(u_mem1.u_if, mem1);
        m0br.start(); m1br.start();

        // Preload source into mem0 (WB0 master memory).
        for (int i = 0; i < NW; i++) begin
            mem0.mem[SRC + 4*i] = 32'hA5A5_0000 + i;
            mem0.mem[DST + 4*i] = 32'h0;
        end

        // Release reset.
        repeat (4) @(posedge clk);
        rst = 1'b0;
        repeat (2) @(posedge clk);

        // Program channel 0 (addresses + size BEFORE CSR: arming latches them).
        wr(CH0_ADR0, SRC);
        wr(CH0_ADR1, DST);
        wr(CH0_SZ,   NW);                                     // chk_sz=0 => whole TOT_SZ
        // CSR: ch_en(0) | inc_dst(3) | inc_src(4) | ine_done(18)
        wr(CH0_CSR, (1<<0)|(1<<3)|(1<<4)|(1<<18));

        // Poll for DONE (CSR bit 11).
        for (int t = 0; t < 4000; t++) begin
            rd(CH0_CSR, csr);
            if (csr[11]) break;
        end
        if (!csr[11]) begin $display("FAIL: channel never completed"); errors++; end

        // Check the destination buffer in mem0.
        for (int i = 0; i < NW; i++) begin
            exp = 32'hA5A5_0000 + i;
            got = mem0.mem.exists(DST + 4*i) ? mem0.mem[DST + 4*i] : 'x;
            if (got !== exp) begin
                $display("FAIL: dst[%0d]@0x%08h = 0x%08h (exp 0x%08h)",
                         i, DST + 4*i, got, exp);
                errors++;
            end
        end

        if (errors == 0) $display("[wb_dma_spl_wb] PASS (%0d words copied over Wishbone)", NW);
        else             $display("[wb_dma_spl_wb] FAIL (%0d errors)", errors);
        $finish;
    end

    initial begin
        #500us;
        $fatal(1, "[wb_dma_spl_wb] TIMEOUT");
    end
endmodule
