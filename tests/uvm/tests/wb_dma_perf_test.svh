// Runs wb_dma_perf_seq and reports transfers/s + words/s. Same test on all three
// DUT flavours (TLM / SPL+xtors / RTL). Plusargs: +PERF_WORDS=<n> +PERF_SECS=<f>
// +PERF_LABEL=<str>. The top must be launched with +PERF (disables the sim-time
// watchdog so the run is bounded by wall-clock, not sim time).
class wb_dma_perf_test extends wb_dma_base_test;
    `uvm_component_utils(wb_dma_perf_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction

    task run_phase(uvm_phase phase);
        wb_dma_perf_seq seq = wb_dma_perf_seq::type_id::create("seq");
        int    tot   = 256;
        real   secs  = 5.0;
        string label = "?";
        void'($value$plusargs("PERF_WORDS=%d", tot));
        void'($value$plusargs("PERF_SECS=%f", secs));
        void'($value$plusargs("PERF_LABEL=%s", label));
        seq.model = model; seq.tot = tot; seq.secs = secs;

        phase.raise_objection(this);
        seq.start(env.m_init.m_seqr);
        `uvm_info("PERF", $sformatf(
            "[%s] words/xfer=%0d  xfers=%0d  words=%0d  wall=%0.3f s  =>  %0.1f xfers/s  %0.3f Mword/s (%0.2f MB/s)",
            label, tot, seq.xfers, seq.words, seq.wall,
            real'(seq.xfers)/seq.wall,
            (real'(seq.words)/seq.wall)/1.0e6,
            (real'(seq.words)*4.0/seq.wall)/1.0e6), UVM_LOW)
        phase.drop_objection(this);
    endtask
endclass
