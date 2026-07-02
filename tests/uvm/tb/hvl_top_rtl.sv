// HVL top for the RTL signal-level UVM path. The DUT is the OpenCores wb_dma_top
// Verilog RTL. The SAME UVM env + tests as the TLM and SPL-wb tops run here --
// only the DUT and its memory backing differ. The model published to the config_db
// is a wb_dma_rtl_model: its register BFM drives a Wishbone initiator into the DUT
// (register access = real WB cycles), its two data memories are combinational
// 0-wait-state SV RAMs (wb_ram_slv) that the DUT masters into DIRECTLY, and
// interrupts are observed off the DUT's inta_o/intb_o PINS via a fwvip-gpio monitor
// feeding the model's int_changed() seam.
//
// Why RAMs (not target transactors) on the master ports: the wb_dma engine is
// designed/proven against a same-cycle memory (cf. wb_dma/bench wb_slv_model.v,
// ack = cyc & stb). A variable-latency FIFO transactor desynchronises the engine's
// chunk/pointer write-back across the test's per-iteration re-programming. The
// host/register port keeps the transactor (it tolerates latency).
//
// The per-channel hardware-handshake bus (dma_req_i/dma_ack_o/dma_nd_i/dma_rest_i)
// is STUBBED here (tied off), so only the non-handshake scenarios (sw_copy, arb)
// run on the RTL path -- matching the SPL-wb top. hw_hs/hol stay on the TLM top.
`include "uvm_macros.svh"
`include "fwvip_gpio_macros.svh"

module hvl_top_rtl;
    import uvm_pkg::*;
    import fw_hdl_pkg::*;
    import fw_proto_wb_pkg::*;
    import fwvip_gpio_pkg::*;
    import wb_dma_model_pkg::*;
    import wb_dma_wb_model_pkg::*;
    import wb_dma_rtl_model_pkg::*;
    import wb_dma_uvm_pkg::*;
    import wb_dma_tests_pkg::*;

    logic clk = 1'b0;
    logic rst = 1'b1;
    always #5ns clk = ~clk;

    // NOTE: the OpenCores RTL tags its one-hot state machines with `// synopsys
    // parallel_case full_case` -- SYNTHESIS-only directives. Event simulators
    // (Icarus/VCS, the RTL's original targets) ignore them; Verilator UNIQUELY
    // promotes them to runtime $stop when no case item matches. At t=0 the state
    // regs read all-zero (Verilator 2-state init) before the first clocked reset
    // load drives them to IDLE, so an unmatched case trips spuriously. The
    // uvm-rtl-img compile passes --no-assert so Verilator matches standard-sim
    // semantics; the design still resets functionally on the first clock edge.

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

    // ---- DUT: the OpenCores wb_dma_top RTL -----------------------------------
    // NB: the OpenCores wb_dma SWAPS the s/m data-bus port names relative to the
    // port role. The SLAVE/CPU register port (wb0_addr_i/cyc_i/...) carries its
    // data on wb0m_data_i/wb0m_data_o; the MASTER/memory port (wb0_addr_o/cyc_o
    // /...) carries its data on wb0s_data_i/wb0s_data_o. (The bench confirms it:
    // the CPU model drives wb0m_data_i, the memory model drives wb0s_data_i.) The
    // wb_dma_spl wrapper used the intuitive convention, so only the DATA buses
    // differ here from hvl_top_spl_wb -- control signals are identical.
    // ch_count sets the channel COUNT, but each channel must be individually
    // instantiated via chN_conf[0] (the "EN"/exists bit; chXX_conf = {CBUF,ED,ARS,
    // EN}). The RTL defaults only ch0_conf=4'h1, so enable ch0..ch3 for the arb
    // scenario (harmless for sw_copy, which uses channel 0 only).
    // pri_sel selects 2 (0) / 4 (1) / 8 (2) priority levels. The arb test programs
    // 4 distinct priorities (0..3) in CSR[15:13] and expects strict priority order,
    // so use 8 levels (2'h2) to honour the full 3-bit priority field.
    wb_dma_top #(.ch_count(4), .pri_sel(2'h2),
                 .ch0_conf(4'h1), .ch1_conf(4'h1), .ch2_conf(4'h1), .ch3_conf(4'h1)) dut (
        .clk_i(clk), .rst_i(rst),
        // IF0 slave / CPU register port (data on wb0m_data_*)
        .wb0m_data_i(h_dat_w), .wb0m_data_o(h_dat_r), .wb0_addr_i(h_adr),
        .wb0_sel_i(h_sel), .wb0_we_i(h_we), .wb0_cyc_i(h_cyc), .wb0_stb_i(h_stb),
        .wb0_ack_o(h_ack), .wb0_err_o(h_err), .wb0_rty_o(),
        // IF0 master / memory port to u_ram0 (data on wb0s_data_*)
        .wb0s_data_i(m0_dat_r), .wb0s_data_o(m0_dat_w), .wb0_addr_o(m0_adr),
        .wb0_sel_o(m0_sel), .wb0_we_o(m0_we), .wb0_cyc_o(m0_cyc), .wb0_stb_o(m0_stb),
        .wb0_ack_i(m0_ack), .wb0_err_i(m0_err), .wb0_rty_i(1'b0),
        // IF1 slave tied off (data on wb1m_data_*)
        .wb1m_data_i(32'h0), .wb1m_data_o(), .wb1_addr_i(32'h0),
        .wb1_sel_i(4'h0), .wb1_we_i(1'b0), .wb1_cyc_i(1'b0), .wb1_stb_i(1'b0),
        .wb1_ack_o(), .wb1_err_o(), .wb1_rty_o(),
        // IF1 master / memory port to u_ram1 (data on wb1s_data_*)
        .wb1s_data_i(m1_dat_r), .wb1s_data_o(m1_dat_w), .wb1_addr_o(m1_adr),
        .wb1_sel_o(m1_sel), .wb1_we_o(m1_we), .wb1_cyc_o(m1_cyc), .wb1_stb_o(m1_stb),
        .wb1_ack_i(m1_ack), .wb1_err_i(m1_err), .wb1_rty_i(1'b0),
        // Hardware-handshake bus stubbed (tied off) for now.
        .dma_req_i(4'h0), .dma_ack_o(dma_ack), .dma_nd_i(4'h0), .dma_rest_i(4'h0),
        .inta_o(inta), .intb_o(intb));

    // ---- host register initiator (transactor) --------------------------------
    wb_initiator_xtor u_host (
        .clock(clk), .reset(rst),
        .adr(h_adr), .dat_w(h_dat_w), .dat_r(h_dat_r),
        .cyc(h_cyc), .stb(h_stb), .sel(h_sel), .we(h_we), .ack(h_ack), .err(h_err));

    // ---- data memories: combinational 0-wait-state WB RAMs on the master ports -
    // (m*_err unused: the RAMs never signal ERR.)
    wb_ram_slv #(.AW(32), .DW(32)) u_ram0 (
        .clock(clk),
        .adr(m0_adr), .dat_w(m0_dat_w), .dat_r(m0_dat_r),
        .sel(m0_sel), .cyc(m0_cyc), .stb(m0_stb), .we(m0_we), .ack(m0_ack));
    wb_ram_slv #(.AW(32), .DW(32)) u_ram1 (
        .clock(clk),
        .adr(m1_adr), .dat_w(m1_dat_w), .dat_r(m1_dat_r),
        .sel(m1_sel), .cyc(m1_cyc), .stb(m1_stb), .we(m1_we), .ack(m1_ack));

    // GPIO monitor tapping the interrupt pins {intb_o, inta_o} (bit0=inta, bit1=intb).
    gpio_monitor_xtor #(.WIDTH(2)) u_mon_int (.clock(clk), .reset(rst), .gpio_i({intb, inta}));

    // Clock domain for the bus-side model tree.
    fw_clock_xtor_if u_clk(.clock(clk), .reset(rst));

    // Wall-clock (real seconds) at startup / finish -- for throughput measurement.
    real wc_start;

    initial begin
        automatic fw_component_root #(wb_dma_rtl_model) root = new("root");
        automatic fw_clock_xtor_bridge clk_dom;
        wc_start = wc_now();
        $display("[PERF] %m START  wallclock=%0.3f s", wc_start);
        // Seat the host initiator vif + the two RAM vifs before start().
        root.vhost  = u_host.u_if;
        root.vram0  = u_ram0;
        root.vram1  = u_ram1;
        clk_dom = new("clock", root, u_clk);
        root.clock.connect(clk_dom);         // seat the root clock domain
        root.start();                        // build -> connect -> run
        // No memory-service fork: the wb_ram_slv RAMs serve the master ports directly.

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
            $fatal(1, "[hvl_top_rtl] TIMEOUT");
        end
    end

    final begin
        real wc_end;
        wc_end = wc_now();
        $display("[PERF] %m FINISH wallclock=%0.3f s  ELAPSED=%0.3f s", wc_end, wc_end - wc_start);
    end
endmodule
