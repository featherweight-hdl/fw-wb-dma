// ======================================================================
// Phase-1 SMOKE test for the wb_dma SPL (class) model.
//
// Proves the class skeleton ELABORATES and RUNS a real transfer, using ONLY
// the protocol-independent fw_mem_if edge -- NO Wishbone, no transactors. The
// engine's two master ports (mif0/mif1) and its register-file slave (rf.host)
// are wired to plain fw_mem_if models:
//
//   cpu_seq --fw_mem_if--> wb_dma.rf.host        (programs the channel regs)
//   wb_dma.de.mif0/mif1 --fw_mem_if--> data_mem  (reads source / writes dest)
//   wb_dma.de.irq --wb_dma_irq_if--> irq_sink      (collects done/err causes)
//
// The test programs channel 0 for a normal-mode (software) block copy of an
// 8-word buffer from 0x1000 to 0x2000 through IF0, waits for DONE, and checks
// the destination. Pure delay-driven (no clock) -- it is a TLM model.
//
// Run:  dfm run fw-wb-dma.smoke      (expect: [wb_dma_smoke] PASS)
// ======================================================================
module wb_dma_smoke_tb;
    import fw_hdl_pkg::*;
    import fw_std_pkg::*;       // fw_mem_if + FW_MEM_IMP
    import wb_dma_spl_pkg::*;     // the DMA class model

    typedef logic [31:0] addr_t;
    typedef logic [31:0] data_t;
    typedef logic [3:0]  strb_t;

    localparam addr_t SRC = 32'h0000_1000;
    localparam addr_t DST = 32'h0000_2000;
    localparam int    NW  = 8;                  // words to copy

    // Channel-0 register offsets (rf decode: 0x20 base, 0x20 stride/channel).
    localparam addr_t CH0_CSR  = 32'h20;
    localparam addr_t CH0_SZ   = 32'h24;
    localparam addr_t CH0_ADR0 = 32'h28;        // source
    localparam addr_t CH0_ADR1 = 32'h30;        // destination

    // ---- fw_mem_if data memory (serves both IF0 and IF1) --------------------
    class data_mem extends fw_component;
        data_t mem [addr_t];
        `FW_MEM_IMP(addr_t, data_t, strb_t, data_mem, m);

        function new(string name, fw_component parent); super.new(name, parent); endfunction
        function void build(); m = new(this); endfunction

        virtual task m_write(output bit err, input addr_t addr, input data_t data,
                             input strb_t strb);
            #7ns; mem[addr] = data; err = 1'b0;
        endtask
        virtual task m_read(output data_t data, output bit err, input addr_t addr);
            #7ns; data = mem.exists(addr) ? mem[addr] : 32'h0; err = 1'b0;
        endtask
    endclass

    // ---- interrupt-cause sink ------------------------------------------------
    class irq_sink extends fw_component;
        wb_dma_irq_evt_t last;
        int unsigned     n_done, n_err, n_chunk;
        `FW_WB_DMA_IRQ_IMP(irq_sink, sink);

        function new(string name, fw_component parent); super.new(name, parent); endfunction
        function void build(); sink = new(this); endfunction

        virtual function void sink_raise(input wb_dma_irq_evt_t evt);
            last = evt;
            case (evt.cause)
                CAUSE_DONE:  n_done++;
                CAUSE_ERR:   n_err++;
                CAUSE_CHUNK: n_chunk++;
                default: ;
            endcase
            $display("[irq] ch%0d cause=%s", evt.channel, evt.cause.name());
        endfunction
    endclass

    // ---- CPU stimulus: programs the channel through the register-file slave --
    class cpu_seq extends fw_component implements fw_runnable;
        fw_port #(fw_mem_if #(addr_t, data_t, strb_t)) regs;  // -> rf.host
        data_mem dmem;                                          // direct: preload/check
        int unsigned errors;

        function new(string name, fw_component parent);
            super.new(name, parent);
            parent.add_runnable(this);
        endfunction
        function void build(); regs = new("regs", this); endfunction

        virtual task run();
            fw_mem_if #(addr_t, data_t, strb_t) rf = regs.get_if();
            automatic bit    err;
            automatic data_t csr;
            errors = 0;

            // Preload source, clear destination.
            for (int i = 0; i < NW; i++) begin
                dmem.mem[SRC + 4*i] = 32'hA5A5_0000 + i;
                dmem.mem[DST + 4*i] = 32'h0;
            end

            // Program channel 0 (addresses + size BEFORE CSR: arming latches them).
            rf.write(err, CH0_ADR0, SRC, 4'hf);
            rf.write(err, CH0_ADR1, DST, 4'hf);
            rf.write(err, CH0_SZ,   NW,  4'hf);          // chk_sz=0 => whole TOT_SZ
            // CSR: ch_en(0) | inc_dst(3) | inc_src(4) | ine_done(18)
            rf.write(err, CH0_CSR, (1<<0)|(1<<3)|(1<<4)|(1<<18), 4'hf);

            // Wait for DONE (CSR bit 11).
            for (int t = 0; t < 2000; t++) begin
                rf.read(csr, err, CH0_CSR);
                if (csr[11]) break;
                #10ns;
            end
            if (!csr[11]) begin $display("FAIL: channel never completed"); errors++; end

            // Check the destination buffer.
            for (int i = 0; i < NW; i++) begin
                automatic data_t exp = 32'hA5A5_0000 + i;
                automatic data_t got = dmem.mem.exists(DST + 4*i) ? dmem.mem[DST + 4*i] : 'x;
                if (got !== exp) begin
                    $display("FAIL: dst[%0d]@0x%08h = 0x%08h (exp 0x%08h)",
                             i, DST + 4*i, got, exp);
                    errors++;
                end
            end

            if (errors == 0) $display("[wb_dma_smoke] PASS (%0d words copied)", NW);
            else             $display("[wb_dma_smoke] FAIL (%0d errors)", errors);
            $finish;
        endtask
    endclass

    // ---- environment: the DMA model + its fw_mem_if peers -------------------
    class smoke_env extends fw_component;
        wb_dma    dma;
        data_mem  dm;
        irq_sink  irq;
        cpu_seq   cpu;

        function new(string name, fw_component parent); super.new(name, parent); endfunction

        function void build();
            dma = new("dma", this, 4);     // 4 channels
            dm  = new("dm",  this);
            irq = new("irq", this);
            cpu = new("cpu", this);
        endfunction

        function void connect();
            cpu.dmem = dm;                 // CPU preloads/checks the data memory directly
            cpu.regs.connect(dma.rf.host); // CPU programs registers
            dma.de.mif0.connect(dm.m);     // IF0 master -> data memory
            dma.de.mif1.connect(dm.m);     // IF1 master -> data memory (resolved at run start)
            dma.de.irq.connect(irq.sink);  // interrupt causes -> sink
        endfunction
    endclass

    // The model is delay-driven (it never ticks), but the fw-hdl lifecycle eagerly
    // resolves every component's inherited `clock` domain during connect, so the
    // root domain must be seated. A trivial free-running clock backs it.
    logic clk = 1'b0;
    logic rst = 1'b0;
    always #5ns clk = ~clk;
    fw_clock_xtor_if u_clk(.clock(clk), .reset(rst));

    initial begin
        automatic fw_component_root #(smoke_env) root = new("root");
        automatic fw_clock_xtor_bridge clk_dom = new("clock", root, u_clk);
        root.clock.connect(clk_dom);       // seat the root clock domain
        root.start();                      // do_build -> do_connect -> do_run (forks runnables)
    end

    initial begin
        #500us;
        $fatal(1, "[wb_dma_smoke] TIMEOUT");
    end
endmodule
