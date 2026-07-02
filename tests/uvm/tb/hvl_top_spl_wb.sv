// HVL top for the SIGNAL-LEVEL (Wishbone) UVM path. The DUT is the wb_dma_spl
// wrapper (the SPL model behind Wishbone pins). The SAME UVM env + tests as the
// TLM top run here -- only the "model" published to the config_db differs: a
// wb_dma_wb_model whose register BFM drives a Wishbone initiator into the DUT and
// whose data memories back the DUT's master ports through Wishbone target
// transactors. Interrupts are reconstructed from INT_SRC register reads.
//
// Only the non-handshake scenarios (sw_copy, arb) run here; the per-channel HS
// bus is stubbed in wb_dma_spl (hw_hs/hol stay on the TLM top, hvl_top_spl).
//
// Interrupts are observed off the DUT's inta_o/intb_o PINS via a fwvip-gpio
// monitor, which feeds the model's int_changed() seam -- the same seam the TLM
// model drives from rf.signal_int, so the bench waits are identical across paths.
`include "uvm_macros.svh"
`include "fwvip_gpio_macros.svh"

module hvl_top_spl_wb;
    import uvm_pkg::*;
    import fw_hdl_pkg::*;
    import fw_proto_wb_pkg::*;
    import fwvip_gpio_pkg::*;
    import wb_dma_model_pkg::*;
    import wb_dma_wb_model_pkg::*;
    import wb_dma_uvm_pkg::*;
    import wb_dma_tests_pkg::*;

    logic clk = 1'b0;
    logic rst = 1'b1;
    always #5ns clk = ~clk;
    // Reset release runs CONCURRENTLY (UVM forbids sim time before run_test()); the
    // transactors hold during reset, so the first bus access simply waits it out.
    initial begin
        rst = 1'b1;
        repeat (5) @(posedge clk);
        rst = 1'b0;
    end

    // ---- three Wishbone buses ------------------------------------------------
    wire [31:0] h_dat_w, h_dat_r, h_adr;  wire [3:0] h_sel;
    wire        h_we, h_cyc, h_stb, h_ack, h_err;
    wire [31:0] m0_adr, m0_dat_w, m0_dat_r;  wire [3:0] m0_sel;
    wire        m0_we, m0_cyc, m0_stb, m0_ack, m0_err;
    wire [31:0] m1_adr, m1_dat_w, m1_dat_r;  wire [3:0] m1_sel;
    wire        m1_we, m1_cyc, m1_stb, m1_ack, m1_err;
    wire        inta, intb;
    wire [3:0]  dma_ack;

    // ---- DUT: the Wishbone-wrapped SPL model ---------------------------------
    wb_dma_spl #(.ch_count(4)) dut (
        .clk_i(clk), .rst_i(rst),
        .wb0s_data_i(h_dat_w), .wb0s_data_o(h_dat_r), .wb0_addr_i(h_adr),
        .wb0_sel_i(h_sel), .wb0_we_i(h_we), .wb0_cyc_i(h_cyc), .wb0_stb_i(h_stb),
        .wb0_ack_o(h_ack), .wb0_err_o(h_err), .wb0_rty_o(),
        .wb0m_data_i(m0_dat_r), .wb0m_data_o(m0_dat_w), .wb0_addr_o(m0_adr),
        .wb0_sel_o(m0_sel), .wb0_we_o(m0_we), .wb0_cyc_o(m0_cyc), .wb0_stb_o(m0_stb),
        .wb0_ack_i(m0_ack), .wb0_err_i(m0_err), .wb0_rty_i(1'b0),
        .wb1s_data_i(32'h0), .wb1s_data_o(), .wb1_addr_i(32'h0),
        .wb1_sel_i(4'h0), .wb1_we_i(1'b0), .wb1_cyc_i(1'b0), .wb1_stb_i(1'b0),
        .wb1_ack_o(), .wb1_err_o(), .wb1_rty_o(),
        .wb1m_data_i(m1_dat_r), .wb1m_data_o(m1_dat_w), .wb1_addr_o(m1_adr),
        .wb1_sel_o(m1_sel), .wb1_we_o(m1_we), .wb1_cyc_o(m1_cyc), .wb1_stb_o(m1_stb),
        .wb1_ack_i(m1_ack), .wb1_err_i(m1_err), .wb1_rty_i(1'b0),
        .dma_req_i(4'h0), .dma_ack_o(dma_ack), .dma_nd_i(4'h0), .dma_rest_i(4'h0),
        .inta_o(inta), .intb_o(intb));

    // ---- external transactors ------------------------------------------------
    wb_initiator_xtor u_host (
        .clock(clk), .reset(rst),
        .adr(h_adr), .dat_w(h_dat_w), .dat_r(h_dat_r),
        .cyc(h_cyc), .stb(h_stb), .sel(h_sel), .we(h_we), .ack(h_ack), .err(h_err));
    wb_target_xtor u_mem0 (
        .clock(clk), .reset(rst),
        .adr(m0_adr), .dat_w(m0_dat_w), .dat_r(m0_dat_r),
        .cyc(m0_cyc), .stb(m0_stb), .sel(m0_sel), .we(m0_we), .ack(m0_ack), .err(m0_err));
    wb_target_xtor u_mem1 (
        .clock(clk), .reset(rst),
        .adr(m1_adr), .dat_w(m1_dat_w), .dat_r(m1_dat_r),
        .cyc(m1_cyc), .stb(m1_stb), .sel(m1_sel), .we(m1_we), .ack(m1_ack), .err(m1_err));

    // GPIO monitor tapping the interrupt pins {intb_o, inta_o} (bit0=inta, bit1=intb).
    gpio_monitor_xtor #(.WIDTH(2)) u_mon_int (.clock(clk), .reset(rst), .gpio_i({intb, inta}));

    // Clock domain for the bus-side model tree.
    fw_clock_xtor_if u_clk(.clock(clk), .reset(rst));

    // Wall-clock (real seconds) at startup / finish -- for throughput measurement.
    real wc_start;

    initial begin
        automatic fw_component_root #(wb_dma_wb_model) root = new("root");
        automatic fw_clock_xtor_bridge clk_dom;
        wc_start = wc_now();
        $display("[PERF] %m START  wallclock=%0.3f s", wc_start);
        // Seat transactor vifs before start() (build() needs vhost).
        root.vhost = u_host.u_if;
        root.vmem0 = u_mem0.u_if;
        root.vmem1 = u_mem1.u_if;
        clk_dom = new("clock", root, u_clk);
        root.clock.connect(clk_dom);         // seat the root clock domain
        root.start();                        // build -> connect -> run
        fork root.m0br.run(); root.m1br.run(); join_none   // master-side WB slaves

        // Bind the interrupt-pin GPIO monitor + swap in the GPIO-augmented env.
        `fwvip_gpio_monitor_register(2, u_mon_int.u_if, "uvm_test_top.env.m_int*")
        wb_dma_env::type_id::set_type_override(wb_dma_wb_env::get_type());

        // No sim time before run_test(): reset is released by the concurrent
        // initial above; the first register access blocks on the bus until then.
        uvm_config_db #(wb_dma_model_base)::set(null, "*", "model", root);
        run_test();
    end

    // Sim-time watchdog (skipped for +PERF runs, which are bounded by wall-clock).
    initial begin
        if (!$test$plusargs("PERF")) begin
            #5ms;
            $fatal(1, "[hvl_top_spl_wb] TIMEOUT");
        end
    end

    final begin
        real wc_end;
        wc_end = wc_now();
        $display("[PERF] %m FINISH wallclock=%0.3f s  ELAPSED=%0.3f s", wc_end, wc_end - wc_start);
    end
endmodule
