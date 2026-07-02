// ======================================================================
// Performance benchmark for the SPL DMA engine CORE -- no Wishbone transactors,
// no UVM. The engine's two master ports (mif0/mif1) and its register slave
// (rf.host) are wired to dense O(1) fw_mem_if memories, so the wall-clock time
// reflects the model itself (register reads, per-chunk arbitration, the
// event-set wait, the transfer loop) rather than memory-model overhead.
//
// A transfer is capped at TOT_SZ = 4095 words by the SZ register, so the bench
// re-arms the same channel ITERS times to move ITERS*NW words total. Memories are
// zero-delay, so each transfer completes in delta cycles -- wall-clock is pure
// engine compute. Throughput = (ITERS*NW) / walltime (read from the $finish line).
//
// Run:  dfm run fw-wb-dma.perf            (defaults: NW=4000 ITERS=1000 CHUNK=0)
//       dfm run fw-wb-dma.perf -- +NW=4000 +ITERS=2000 +CHUNK=16
// ======================================================================
`include "fw_hdl_macros.svh"

module wb_dma_perf_tb;
    import fw_hdl_pkg::*;
    import fw_std_pkg::*;
    import wb_dma_spl_pkg::*;

    typedef logic [31:0] addr_t;
    typedef logic [31:0] data_t;
    typedef logic [3:0]  strb_t;

    // Knobs (plusargs override the defaults). NW <= 4095, CHUNK <= 511.
    int NW    = 4000;       // words per transfer (TOT_SZ)
    int ITERS = 1000;       // number of transfers (channel re-arms)
    int CHUNK = 0;          // 0 => whole transfer in one chunk

    // Channel-0 register offsets (0x20 base, 0x20 stride).
    localparam addr_t CH0_CSR  = 32'h20;
    localparam addr_t CH0_SZ   = 32'h24;
    localparam addr_t CH0_ADR0 = 32'h28;   // source       (IF0)
    localparam addr_t CH0_ADR1 = 32'h30;   // destination  (IF1)

    // ---- dense O(1) fw_mem_if memory ----------------------------------------
    class dense_mem extends fw_component;
        data_t arr[];
        `FW_MEM_IMP(addr_t, data_t, strb_t, dense_mem, m);
        function new(string name, fw_component parent, int n);
            super.new(name, parent);
            arr = new[n];
        endfunction
        function void build(); m = new(this); endfunction
        virtual task m_write(output bit err, input addr_t a, input data_t d, input strb_t s);
            arr[a>>2] = d; err = 1'b0;
        endtask
        virtual task m_read(output data_t d, output bit err, input addr_t a);
            d = arr[a>>2]; err = 1'b0;
        endtask
    endclass

    // ---- interrupt sink (engine requires a bound irq port) -------------------
    class irq_sink extends fw_component;
        int unsigned n_done;
        `FW_WB_DMA_IRQ_IMP(irq_sink, sink);
        function new(string name, fw_component parent); super.new(name, parent); endfunction
        function void build(); sink = new(this); endfunction
        virtual function void sink_raise(input wb_dma_irq_evt_t evt);
            if (evt.cause == CAUSE_DONE) n_done++;
        endfunction
    endclass

    // ---- driver: program once, then re-arm ITERS times, timing the loop ------
    class perf_cpu extends fw_component implements fw_runnable;
        fw_port #(fw_mem_if #(addr_t, data_t, strb_t)) regs;   // -> rf.host
        function new(string name, fw_component parent);
            super.new(name, parent); parent.add_runnable(this);
        endfunction
        function void build(); regs = new("regs", this); endfunction

        virtual task run();
            fw_mem_if #(addr_t, data_t, strb_t) rf = regs.get_if();
            automatic bit    err;
            automatic data_t csr;
            // CSR: ch_en(0) | dst_sel=IF1(1) | inc_dst(3) | inc_src(4)
            automatic data_t CSR_GO = (1<<0)|(1<<1)|(1<<3)|(1<<4);

            // Addresses + size programmed once; re-arming reloads from them.
            rf.write(err, CH0_ADR0, 32'h0, 4'hf);
            rf.write(err, CH0_ADR1, 32'h0, 4'hf);
            rf.write(err, CH0_SZ, (CHUNK << 16) | NW, 4'hf);

            $display("[perf] start: %0d transfers x %0d words (chunk=%0d) = %0d words",
                     ITERS, NW, CHUNK, ITERS*NW);

            for (int t = 0; t < ITERS; t++) begin
                rf.write(err, CH0_CSR, CSR_GO, 4'hf);          // arm
                do begin
                    #1;
                    rf.read(csr, err, CH0_CSR);
                end while (!csr[11]);                          // wait DONE
            end

            $display("[perf] done: %0d words moved at $time=%0t", ITERS*NW, $time);
            $finish;
        endtask
    endclass

    // ---- environment ---------------------------------------------------------
    class perf_env extends fw_component;
        wb_dma    dma;
        dense_mem s0, s1;     // IF0 (src) / IF1 (dst)
        irq_sink  irq;
        perf_cpu  cpu;
        int       words = 4096;   // memory depth; set before start()
        function new(string name, fw_component parent);
            super.new(name, parent);
        endfunction
        function void build();
            dma = new("dma", this, 4);
            s0  = new("s0", this, words);
            s1  = new("s1", this, words);
            irq = new("irq", this);
            cpu = new("cpu", this);
        endfunction
        function void connect();
            cpu.regs.connect(dma.rf.host);
            dma.de.mif0.connect(s0.m);
            dma.de.mif1.connect(s1.m);
            dma.de.irq.connect(irq.sink);
        endfunction
    endclass

    // root clock domain (model is delay-driven; clock just seats the lifecycle)
    logic clk = 1'b0, rst = 1'b0;
    always #5ns clk = ~clk;
    fw_clock_xtor_if u_clk(.clock(clk), .reset(rst));

    initial begin
        fw_component_root #(perf_env) root;
        fw_clock_xtor_bridge clk_dom;
        if (!$value$plusargs("NW=%d",    NW))    NW    = 4000;
        if (!$value$plusargs("ITERS=%d", ITERS)) ITERS = 1000;
        if (!$value$plusargs("CHUNK=%d", CHUNK)) CHUNK = 0;

        root    = new("root");
        root.words = NW;                    // memory depth = one transfer's span
        clk_dom = new("clock", root, u_clk);
        root.clock.connect(clk_dom);
        root.start();
    end

    initial begin
        #50ms;
        $fatal(1, "[perf] TIMEOUT");
    end
endmodule
