// HVL top for the SPL (class-model) UVM path. No signal-level DUT -- the "DUT"
// is the wb_dma fw-hdl class tree, brought up here as a wb_dma_spl_env (engine +
// two fw_mem_if memories + irq collector + per-channel HS devices). This top:
//   1. elaborates the model env under fw_component_root and forks its runnable(s),
//   2. publishes the model env handle into the uvm_config_db (the UVM reg agent
//      reaches the engine register slave through model.rf_if(); the scoreboard
//      reads the memories / irq collector by backdoor), then
//   3. runs the selected UVM test (+UVM_TESTNAME).
`include "uvm_macros.svh"

module hvl_top_spl;
    import uvm_pkg::*;
    import fw_hdl_pkg::*;
    import wb_dma_model_pkg::*;
    import wb_dma_uvm_pkg::*;
    import wb_dma_tests_pkg::*;

    // The model is delay-driven (it never ticks), but the fw-hdl lifecycle eagerly
    // resolves every component's inherited `clock` domain during connect, so the
    // root domain must be seated. A trivial free-running clock backs it.
    logic clk = 1'b0;
    logic rst = 1'b0;
    always #5ns clk = ~clk;
    fw_clock_xtor_if u_clk(.clock(clk), .reset(rst));

    // Wall-clock (real seconds) at startup / finish -- for throughput measurement.
    real wc_start;

    initial begin
        automatic fw_component_root #(wb_dma_tlm_model) root = new("root");
        automatic fw_clock_xtor_bridge clk_dom = new("clock", root, u_clk);
        wc_start = wc_now();
        $display("[PERF] %m START  wallclock=%0.3f s", wc_start);
        root.clock.connect(clk_dom);  // seat the root clock domain
        root.start(); // do_build -> do_connect -> do_run (forks the mover); returns
        uvm_config_db #(wb_dma_model_base)::set(null, "*", "model", root);
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
