// HVL top for the SPL (class-model) UVM path. No signal-level DUT -- the "DUT"
// is the wb_dma fw-hdl class tree, brought up here as a wb_dma_tlm_model (engine +
// two fw_mem_if memories + irq collector + per-channel HS devices). This top:
//   1. instances hdl_top_spl (the clock substrate),
//   2. elaborates the model root under fw_component_root and forks its runnable(s),
//   3. publishes the model handle into the uvm_config_db (the UVM reg agent
//      reaches the engine register slave through model.rf_if(); the scoreboard
//      reads the memories / irq collector by backdoor), then
//   4. runs the selected UVM test (+UVM_TESTNAME).
//
// The instance of hdl_top_spl is named after the type (emulation convention);
// the HVL reaches its clock interface hierarchically (hdl_top_spl.u_clk).
`include "uvm_macros.svh"

module hvl_top_spl;
    import uvm_pkg::*;
    import fw_hdl_pkg::*;
    import fw_proto_wb_pkg::*;
    import fwvip_wb_pkg::*;
    import wb_dma_model_pkg::*;
    import wb_dma_uvm_pkg::*;
    import wb_dma_tests_pkg::*;

    // Signal-level substrate (clock/reset + clock xtor) lives in hdl_top_spl.
    hdl_top_spl hdl_top_spl();

    // Wall-clock (real seconds) at startup / finish -- for throughput measurement.
    real wc_start;

    initial begin
        automatic fw_component_root #(wb_dma_tlm_model) root = new("root");
        automatic fw_clock_period_xtor_bridge clk_dom = new("clock", root, hdl_top_spl.u_clk.u_if);
        wc_start = wc_now();
        $display("[PERF] %m START  wallclock=%0.3f s", wc_start);
        root.clock.connect(clk_dom);  // seat the root clock domain
        root.start(); // do_build -> do_connect -> do_run (forks the mover); returns
        uvm_config_db #(wb_dma_model_base)::set(null, "*", "model", root);
        // Bind the fwvip-wb initiator to the model's wb_proto_if register port
        // (TLM: direct method calls into the engine's register file).
        fwvip_wb_initiator_config_ap #(32, 32)::set(
            null, "uvm_test_top.env.m_init*", "cfg", root.rf_if());
        run_test();
    end

    // Sim-time watchdog (skipped for +PERF runs, which are bounded by wall-clock).
    initial begin
        if (!$test$plusargs("PERF")) begin
            #5ms;
            $fatal(1, "[hvl_top_spl] TIMEOUT");
        end
    end

    final begin
        real wc_end;
        wc_end = wc_now();
        $display("[PERF] %m FINISH wallclock=%0.3f s  ELAPSED=%0.3f s", wc_end, wc_end - wc_start);
    end
endmodule
