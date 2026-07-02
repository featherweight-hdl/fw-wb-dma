// ======================================================================
// wb_dma_spl -- signal-level Wishbone wrapper around the wb_dma class model.
//
// Ports are IDENTICAL to the OpenCores RTL wb_dma_top
// (packages/wb_dma/rtl/verilog/wb_dma_top.v): two Wishbone interfaces, each with
// a slave + a master port, plus the per-channel DMA handshake bus and the two
// interrupt lines. It is a drop-in replacement at the pin level, backed by the
// behavioral model instead of RTL.
//
// Internally it instances the fw-proto-wb Wishbone transactors and roots the
// wb_dma class model, bridging the two with the fw_mem_if adapters:
//   WB0 slave  --wb_target_xtor--> wb_mem_target   --> dma.rf.host   (host regs)
//   WB0 master <--wb_initiator_xtor-- wb_mem_initiator <-- dma.de.mif0 (IF0 data)
//   WB1 master <--wb_initiator_xtor-- wb_mem_initiator <-- dma.de.mif1 (IF1 data)
//   WB1 slave  -- tied off (Not Connected, mirrors the RTL slv1)
//
// The per-channel HW-handshake bus (dma_req_i/dma_ack_o/dma_nd_i/dma_rest_i) is
// exposed on the top but STUBBED -- not wired to the engine's de.hs[] ports for
// now (dma_ack_o driven to 0). The engine already treats unconnected HS ports as
// null, so HW-handshake channels simply never become "ready".
//
// The config parameters (rf_addr/pri_sel/chN_conf) are carried verbatim for a
// literal drop-in signature with wb_dma_top, but are inert here -- the class model
// is not parameterized by them. ch_count sizes the handshake bus.
// ======================================================================
`include "fw_hdl_macros.svh"
`include "wb_dma_spl_macros.svh"     // FW_WB_DMA_IRQ_IMP (+ FW_MEM_IMP via fw_std)

module wb_dma_spl #(
    parameter        rf_addr   = 0,
    parameter [1:0]  pri_sel   = 2'h0,
    parameter        ch_count  = 1,
    parameter [3:0]  ch0_conf  = 4'h1,
    parameter [3:0]  ch1_conf  = 4'h0,
    parameter [3:0]  ch2_conf  = 4'h0,
    parameter [3:0]  ch3_conf  = 4'h0,
    parameter [3:0]  ch4_conf  = 4'h0,
    parameter [3:0]  ch5_conf  = 4'h0,
    parameter [3:0]  ch6_conf  = 4'h0,
    parameter [3:0]  ch7_conf  = 4'h0,
    parameter [3:0]  ch8_conf  = 4'h0,
    parameter [3:0]  ch9_conf  = 4'h0,
    parameter [3:0]  ch10_conf = 4'h0,
    parameter [3:0]  ch11_conf = 4'h0,
    parameter [3:0]  ch12_conf = 4'h0,
    parameter [3:0]  ch13_conf = 4'h0,
    parameter [3:0]  ch14_conf = 4'h0,
    parameter [3:0]  ch15_conf = 4'h0,
    parameter [3:0]  ch16_conf = 4'h0,
    parameter [3:0]  ch17_conf = 4'h0,
    parameter [3:0]  ch18_conf = 4'h0,
    parameter [3:0]  ch19_conf = 4'h0,
    parameter [3:0]  ch20_conf = 4'h0,
    parameter [3:0]  ch21_conf = 4'h0,
    parameter [3:0]  ch22_conf = 4'h0,
    parameter [3:0]  ch23_conf = 4'h0,
    parameter [3:0]  ch24_conf = 4'h0,
    parameter [3:0]  ch25_conf = 4'h0,
    parameter [3:0]  ch26_conf = 4'h0,
    parameter [3:0]  ch27_conf = 4'h0,
    parameter [3:0]  ch28_conf = 4'h0,
    parameter [3:0]  ch29_conf = 4'h0,
    parameter [3:0]  ch30_conf = 4'h0
) (
    input               clk_i,
    input               rst_i,

    // -------- WISHBONE INTERFACE 0 : Slave (host register access) --------
    input      [31:0]   wb0s_data_i,
    output     [31:0]   wb0s_data_o,
    input      [31:0]   wb0_addr_i,
    input      [3:0]    wb0_sel_i,
    input               wb0_we_i,
    input               wb0_cyc_i,
    input               wb0_stb_i,
    output              wb0_ack_o,
    output              wb0_err_o,
    output              wb0_rty_o,
    // -------- WISHBONE INTERFACE 0 : Master (IF0 data mover) --------
    input      [31:0]   wb0m_data_i,
    output     [31:0]   wb0m_data_o,
    output     [31:0]   wb0_addr_o,
    output     [3:0]    wb0_sel_o,
    output              wb0_we_o,
    output              wb0_cyc_o,
    output              wb0_stb_o,
    input               wb0_ack_i,
    input               wb0_err_i,
    input               wb0_rty_i,

    // -------- WISHBONE INTERFACE 1 : Slave (Not Connected) --------
    input      [31:0]   wb1s_data_i,
    output     [31:0]   wb1s_data_o,
    input      [31:0]   wb1_addr_i,
    input      [3:0]    wb1_sel_i,
    input               wb1_we_i,
    input               wb1_cyc_i,
    input               wb1_stb_i,
    output              wb1_ack_o,
    output              wb1_err_o,
    output              wb1_rty_o,
    // -------- WISHBONE INTERFACE 1 : Master (IF1 data mover) --------
    input      [31:0]   wb1m_data_i,
    output     [31:0]   wb1m_data_o,
    output     [31:0]   wb1_addr_o,
    output     [3:0]    wb1_sel_o,
    output              wb1_we_o,
    output              wb1_cyc_o,
    output              wb1_stb_o,
    input               wb1_ack_i,
    input               wb1_err_i,
    input               wb1_rty_i,

    // -------- Per-channel DMA handshake (STUBBED -- not wired to core) --------
    input  [ch_count-1:0] dma_req_i,
    output [ch_count-1:0] dma_ack_o,
    input  [ch_count-1:0] dma_nd_i,
    input  [ch_count-1:0] dma_rest_i,

    // -------- Interrupts --------
    output              inta_o,
    output              intb_o
);
    import fw_hdl_pkg::*;
    import fw_std_pkg::*;
    import fw_proto_wb_pkg::*;
    import wb_dma_spl_pkg::*;

    // ------------------------------------------------------------------
    // Trivial interrupt sink: the engine raises causes through de.irq, but the
    // level interrupt outputs (inta_o/intb_o) are taken from the register file's
    // aggregated view (rf.inta()/intb()), so this sink only needs to exist so the
    // engine's irq port resolves.
    // ------------------------------------------------------------------
    class wb_dma_irq_null extends fw_component;
        `FW_WB_DMA_IRQ_IMP(wb_dma_irq_null, sink);
        function new(string name, fw_component parent); super.new(name, parent); endfunction
        function void build(); sink = new(this); endfunction
        function void sink_raise(input wb_dma_irq_evt_t evt); /* level output via rf */ endfunction
    endclass

    // ------------------------------------------------------------------
    // Environment: the DMA model + the transactor bridges/adapters. Rooted below;
    // the module seats the transactor virtual interfaces before start().
    // ------------------------------------------------------------------
    class wb_dma_spl_env extends fw_component;
        int unsigned n_ch = 1;

        // Transactor virtual interfaces (seated by the module before start()).
        virtual wb_target_xtor_if    #(32, 32) vslv0;
        virtual wb_initiator_xtor_if #(32, 32) vmst0, vmst1;

        wb_dma            dma;                       // the class model
        wb_dma_irq_null   irqs;                      // interrupt sink

        // Adapters + bridges (plain classes for the bridges).
        wb_initiator_xtor_bridge #(32, 32) ibr0, ibr1;
        wb_mem_initiator                   adapt0, adapt1;   // fw_mem_if -> WB master
        wb_mem_target                      tgt_handler;      // WB slave  -> fw_mem_if
        wb_target_xtor_bridge    #(32, 32) tbr;

        function new(string name, fw_component parent); super.new(name, parent); endfunction

        function void build();
            dma  = new("dma", this, n_ch);
            irqs = new("irqs", this);
            // Initiator bridges drive the two master transactors; the adapters
            // PROVIDE fw_mem_if to the engine's master ports over them.
            ibr0 = new(vmst0);
            ibr1 = new(vmst1);
            adapt0 = new("adapt0", this, ibr0);
            adapt1 = new("adapt1", this, ibr1);
        endfunction

        function void connect();
            // Engine masters -> WB master transactors (via the adapters).
            dma.de.mif0.connect(adapt0.mem);
            dma.de.mif1.connect(adapt1.mem);
            // Interrupt causes -> sink.
            dma.de.irq.connect(irqs.sink);
            // WB slave transactor -> host register file: the target bridge calls
            // the wb_mem_target handler, which forwards to dma.rf.host (fw_mem_if).
            // The service loop (tbr.run) is forked by the module after start()
            // (connect() is a function and cannot start a task).
            tgt_handler = new(dma.rf.host);
            tbr = new(vslv0, tgt_handler);
        endfunction
    endclass

    // ================= transactors on the pins =================
    // WB0 slave: host register access.
    wb_target_xtor u_slv0 (
        .clock(clk_i), .reset(rst_i),
        .adr(wb0_addr_i), .dat_w(wb0s_data_i), .dat_r(wb0s_data_o),
        .cyc(wb0_cyc_i), .stb(wb0_stb_i), .sel(wb0_sel_i), .we(wb0_we_i),
        .ack(wb0_ack_o), .err(wb0_err_o));
    assign wb0_rty_o = 1'b0;                         // transactor has no RTY

    // WB0 master: IF0 data mover (de.mif0).
    wb_initiator_xtor u_mst0 (
        .clock(clk_i), .reset(rst_i),
        .adr(wb0_addr_o), .dat_w(wb0m_data_o), .dat_r(wb0m_data_i),
        .cyc(wb0_cyc_o), .stb(wb0_stb_o), .sel(wb0_sel_o), .we(wb0_we_o),
        .ack(wb0_ack_i), .err(wb0_err_i));          // wb0_rty_i ignored

    // WB1 master: IF1 data mover (de.mif1).
    wb_initiator_xtor u_mst1 (
        .clock(clk_i), .reset(rst_i),
        .adr(wb1_addr_o), .dat_w(wb1m_data_o), .dat_r(wb1m_data_i),
        .cyc(wb1_cyc_o), .stb(wb1_stb_o), .sel(wb1_sel_o), .we(wb1_we_o),
        .ack(wb1_ack_i), .err(wb1_err_i));          // wb1_rty_i ignored

    // WB1 slave: Not Connected (mirrors RTL slv1).
    assign wb1s_data_o = 32'h0;
    assign wb1_ack_o   = 1'b0;
    assign wb1_err_o   = 1'b0;
    assign wb1_rty_o   = 1'b0;

    // DMA handshake: stubbed (not wired to the engine).
    assign dma_ack_o = '0;

    // ================= clock domain + model root =================
    fw_clock_xtor_if u_clk (.clock(clk_i), .reset(rst_i));

    fw_component_root #(wb_dma_spl_env) root;

    initial begin
        automatic fw_clock_xtor_bridge clk_dom;
        root = new("root");
        root.n_ch  = ch_count;
        root.vslv0 = u_slv0.u_if;
        root.vmst0 = u_mst0.u_if;
        root.vmst1 = u_mst1.u_if;
        clk_dom = new("clock", root, u_clk);
        root.clock.connect(clk_dom);                // seat the root clock domain
        root.start();                               // build -> connect -> run
        fork root.tbr.run(); join_none              // WB0-slave service loop
    end

    // ================= interrupt level outputs =================
    // Sample the register file's aggregated interrupt view onto the pins.
    reg inta_r = 1'b0, intb_r = 1'b0;
    always @(posedge clk_i) begin
        if (root != null) begin
            inta_r <= root.dma.rf.inta();
            intb_r <= root.dma.rf.intb();
        end
    end
    assign inta_o = inta_r;
    assign intb_o = intb_r;

endmodule
