// ======================================================================
// Scenario sequences + tests for the wb_dma SPL UVM environment.
//
// Scenarios mirror packages/wb_dma/bench (Phase-1 subset):
//   * wb_dma_sw_copy_test  -- sw_dma1/2: single-channel block copy across the
//        four src/dst-select modes, swept tot_sz/chunk_sz, interrupt bank A/B.
// (arbitration + HW-handshake scenarios are added on top of this base.)
// ======================================================================
`include "uvm_macros.svh"

package wb_dma_tests_pkg;
    import uvm_pkg::*;
    import wb_dma_model_pkg::*;
    import wb_dma_uvm_pkg::*;

    localparam logic [31:0] SRC_BASE = 32'h0000_0000;
    localparam logic [31:0] DST_BASE = 32'h0000_4000;

    // ---- single-channel SW block-copy sequence -------------------------------
    class wb_dma_sw_copy_seq extends wb_dma_base_seq;
        `uvm_object_utils(wb_dma_sw_copy_seq)
        bit src_sel = 0;
        bit dst_sel = 0;
        int tot      = 16;
        int chunk    = 4;     // 0 => whole transfer in one chunk
        bit int_bank = 0;     // 0=A, 1=B

        function new(string name = "wb_dma_sw_copy_seq"); super.new(name); endfunction

        task body();
            logic [31:0] v;
            wb_dma_mem   srcm = model.mem(src_sel);

            model.irqc.reset();
            srcm.fill(SRC_BASE, tot, 16'hC0DE);

            reg_write(int_bank ? REG_INT_MASKB : REG_INT_MASKA, 32'hffff_ffff);
            reg_write(CH_TXSZ(0), mk_sz(chunk, tot));
            reg_write(CH_ADR0(0), SRC_BASE);
            reg_write(CH_ADR1(0), DST_BASE);
            reg_write(CH_CSR(0),  mk_csr(.ch_en(1), .src_sel(src_sel), .dst_sel(dst_sel),
                                         .inc_src(1), .inc_dst(1), .mode_hs(0), .ars(0),
                                         .prio(3'd0), .ine_done(1)));

            wait_int(int_bank ? REG_INT_SRCB : REG_INT_SRCA, 32'h1, v);
            if (!v[0])
                `uvm_error("SWCOPY", "channel 0 done interrupt never observed")
        endtask
    endclass

    // ---- 4-channel priority arbitration sequence -----------------------------
    // All channels copy an equal block (mode 0->0, distinct regions) but at
    // distinct priorities; the engine must complete them highest-priority-first.
    class wb_dma_arb_seq extends wb_dma_base_seq;
        `uvm_object_utils(wb_dma_arb_seq)
        int          n_ch = 4;
        int          tot  = 32;
        int          chunk = 4;
        int unsigned prio[];                  // per-channel priority

        function new(string name = "wb_dma_arb_seq"); super.new(name); endfunction

        // src base for channel c (0x80-byte stride, like the bench).
        function logic [31:0] src_base(int c); return 32'h0000_0000 + c*32'h80; endfunction
        function logic [31:0] dst_base(int c); return 32'h0000_4000 + c*32'h80; endfunction

        task body();
            model.irqc.reset();
            // Fill each channel's distinct source region (IF0 == s0).
            foreach (prio[c]) model.s0.fill(src_base(c), tot, 16'(16'hB000 + c));

            reg_write(REG_INT_MASKA, 32'hffff_ffff);
            // Program all channels' addresses/size first ...
            foreach (prio[c]) begin
                reg_write(CH_TXSZ(c), mk_sz(chunk, tot));
                reg_write(CH_ADR0(c), src_base(c));
                reg_write(CH_ADR1(c), dst_base(c));
            end
            // ... then arm them (per-chunk re-arbitration => strict priority order).
            foreach (prio[c])
                reg_write(CH_CSR(c), mk_csr(.ch_en(1), .src_sel(0), .dst_sel(0),
                                            .inc_src(1), .inc_dst(1), .mode_hs(0), .ars(0),
                                            .prio(3'(prio[c])), .ine_done(1)));

            wait_done(prio.size());
        endtask
    endclass

    // ---- HW-handshake sequence (mode=1): one chunk per external request ------
    class wb_dma_hw_hs_seq extends wb_dma_base_seq;
        `uvm_object_utils(wb_dma_hw_hs_seq)
        bit src_sel = 0;
        bit dst_sel = 0;
        int tot     = 32;
        int chunk   = 4;        // 0 => whole transfer is one chunk

        function new(string name = "wb_dma_hw_hs_seq"); super.new(name); endfunction

        task body();
            logic [31:0] v;
            int          k;     // number of chunks (== external requests)
            wb_dma_mem   srcm = model.mem(src_sel);

            model.irqc.reset();
            srcm.fill(SRC_BASE, tot, 16'hAA00);

            reg_write(REG_INT_MASKA, 32'hffff_ffff);
            reg_write(CH_TXSZ(0), mk_sz(chunk, tot));
            reg_write(CH_ADR0(0), SRC_BASE);
            reg_write(CH_ADR1(0), DST_BASE);
            reg_write(CH_CSR(0),  mk_csr(.ch_en(1), .src_sel(src_sel), .dst_sel(dst_sel),
                                         .inc_src(1), .inc_dst(1), .mode_hs(1), .ars(0),
                                         .prio(3'd0), .ine_done(1)));

            k = (chunk == 0) ? 1 : ((tot + chunk - 1) / chunk);
            // Drive one external request per chunk; each blocks until the engine
            // acks that chunk (models dma_req/dma_ack).
            for (int i = 0; i < k; i++)
                model.hsdev[0].request_chunk();

            wait_int(REG_INT_SRCA, 32'h1, v);
            if (!v[0])
                `uvm_error("HWHS", "channel 0 done interrupt never observed")
        endtask
    endclass

    // ---- base test: build env, publish model, report ------------------------
    class wb_dma_base_test extends uvm_test;
        `uvm_component_utils(wb_dma_base_test)
        wb_dma_env     env;
        wb_dma_model_base model;

        function new(string name, uvm_component parent); super.new(name, parent); endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db #(wb_dma_model_base)::get(this, "", "model", model))
                `uvm_fatal("CFG", "no model env in config_db")
            env = wb_dma_env::type_id::create("env", this);
        endfunction

        function void report_phase(uvm_phase phase);
            if (env.sb.errors == 0)
                `uvm_info("RESULT", "** TEST PASSED **", UVM_LOW)
            else
                `uvm_error("RESULT", $sformatf("** TEST FAILED (%0d errors) **", env.sb.errors))
        endfunction
    endclass

    // ---- SW block-copy test: sweep modes x sizes x chunks --------------------
    class wb_dma_sw_copy_test extends wb_dma_base_test;
        `uvm_component_utils(wb_dma_sw_copy_test)
        function new(string name, uvm_component parent); super.new(name, parent); endfunction

        task run_phase(uvm_phase phase);
            int sizes[]  = '{1, 7, 16, 33};
            int chunks[] = '{0, 4, 5};
            phase.raise_objection(this);
            for (int mode = 0; mode < 4; mode++) begin
                bit ss = mode[1];   // src_sel
                bit ds = mode[0];   // dst_sel
                foreach (sizes[si]) foreach (chunks[ci]) begin
                    wb_dma_sw_copy_seq seq = wb_dma_sw_copy_seq::type_id::create("seq");
                    seq.model    = model;
                    seq.src_sel  = ss;
                    seq.dst_sel  = ds;
                    seq.tot      = sizes[si];
                    seq.chunk    = chunks[ci];
                    seq.int_bank = mode[0];   // exercise both interrupt banks
                    seq.start(env.agent.sqr);

                    env.sb.check_copy(ss, SRC_BASE, ds, DST_BASE, sizes[si]);
                    env.sb.check_done_count(1);
                end
                `uvm_info("SWCOPY", $sformatf("mode %0d (%0d->%0d) done", mode, mode[1], mode[0]), UVM_LOW)
            end
            phase.drop_objection(this);
        endtask
    endclass

    // ---- arbitration test: 4 channels, distinct priorities -------------------
    class wb_dma_arb_test extends wb_dma_base_test;
        `uvm_component_utils(wb_dma_arb_test)
        function new(string name, uvm_component parent); super.new(name, parent); endfunction

        task run_phase(uvm_phase phase);
            wb_dma_arb_seq    seq;
            int unsigned      prio[]     = '{1, 3, 0, 2};   // ch0..ch3 priorities
            int unsigned      exp_order[] = '{1, 3, 0, 2};  // highest-priority first
            phase.raise_objection(this);

            seq = wb_dma_arb_seq::type_id::create("seq");
            seq.model = model;
            seq.prio  = prio;
            seq.tot   = 32;
            seq.chunk = 4;
            seq.start(env.agent.sqr);

            // Each channel's block copied correctly (distinct 0x80-byte regions).
            foreach (prio[c])
                env.sb.check_copy(0, seq.src_base(c), 0, seq.dst_base(c), seq.tot);
            env.sb.check_done_count(4);
            env.sb.check_order(exp_order);
            `uvm_info("ARB", $sformatf("completion order = %p", model.irqc.done_order), UVM_LOW)

            phase.drop_objection(this);
        endtask
    endclass

    // ---- head-of-line sequence: a stalled HS channel must not starve others --
    // Arms an HW-handshake channel (ch1) but issues NO request, then arms a SW
    // channel (ch0). If the engine arbitrated-then-blocked on ch1's wait_req it
    // would starve ch0 forever; with HS gating ch1 is simply not ready, so ch0
    // runs to completion. Afterwards ch1 is fed and must also finish.
    class wb_dma_hol_seq extends wb_dma_base_seq;
        `uvm_object_utils(wb_dma_hol_seq)
        int tot   = 16;
        int chunk = 4;
        localparam logic [31:0] SW_SRC = 32'h0000_0000, SW_DST = 32'h0000_4000;
        localparam logic [31:0] HS_SRC = 32'h0000_0800, HS_DST = 32'h0000_4800;

        function new(string name = "wb_dma_hol_seq"); super.new(name); endfunction

        task body();
            logic [31:0] v;
            int          k;

            model.irqc.reset();
            model.s0.fill(SW_SRC, tot, 16'h5000);
            model.s0.fill(HS_SRC, tot, 16'hB100);              // distinct pattern
            reg_write(REG_INT_MASKA, 32'hffff_ffff);

            // Arm the HS channel FIRST (head of the arbiter scan) but never request
            // -- it must stay un-ready and yield to ch0.
            reg_write(CH_TXSZ(1), mk_sz(chunk, tot));
            reg_write(CH_ADR0(1), HS_SRC);
            reg_write(CH_ADR1(1), HS_DST);
            reg_write(CH_CSR(1),  mk_csr(.ch_en(1), .src_sel(0), .dst_sel(0),
                                         .inc_src(1), .inc_dst(1), .mode_hs(1), .ars(0),
                                         .prio(3'd0), .ine_done(1)));

            // Arm the SW channel; it must complete despite the stalled HS channel.
            reg_write(CH_TXSZ(0), mk_sz(chunk, tot));
            reg_write(CH_ADR0(0), SW_SRC);
            reg_write(CH_ADR1(0), SW_DST);
            reg_write(CH_CSR(0),  mk_csr(.ch_en(1), .src_sel(0), .dst_sel(0),
                                         .inc_src(1), .inc_dst(1), .mode_hs(0), .ars(0),
                                         .prio(3'd0), .ine_done(1)));

            wait_int(REG_INT_SRCA, 32'h1, v);          // bit0 = ch0 (SW) done
            if (!v[0])
                `uvm_error("HOL", "SW channel 0 starved behind stalled HS channel 1")

            // Now feed the HS channel; it must complete too.
            k = (chunk == 0) ? 1 : ((tot + chunk - 1) / chunk);
            for (int i = 0; i < k; i++) model.hsdev[1].request_chunk();
            wait_int(REG_INT_SRCA, 32'h2, v);          // bit1 = ch1 (HS) done
            if (!v[1])
                `uvm_error("HOL", "HS channel 1 never completed after its requests")
        endtask
    endclass

    // ---- HW-handshake test: one chunk per external request -------------------
    class wb_dma_hw_hs_test extends wb_dma_base_test;
        `uvm_component_utils(wb_dma_hw_hs_test)
        function new(string name, uvm_component parent); super.new(name, parent); endfunction

        task run_phase(uvm_phase phase);
            int chunks[] = '{0, 4, 8};
            phase.raise_objection(this);
            for (int mode = 0; mode < 4; mode++) begin
                bit ss = mode[1];
                bit ds = mode[0];
                foreach (chunks[ci]) begin
                    wb_dma_hw_hs_seq seq = wb_dma_hw_hs_seq::type_id::create("seq");
                    seq.model   = model;
                    seq.src_sel = ss;
                    seq.dst_sel = ds;
                    seq.tot     = 32;
                    seq.chunk   = chunks[ci];
                    seq.start(env.agent.sqr);

                    env.sb.check_copy(ss, SRC_BASE, ds, DST_BASE, seq.tot);
                    env.sb.check_done_count(1);
                end
                `uvm_info("HWHS", $sformatf("mode %0d (%0d->%0d) done", mode, mode[1], mode[0]), UVM_LOW)
            end
            phase.drop_objection(this);
        endtask
    endclass

    // ---- head-of-line test: stalled HS channel must not block a SW channel ---
    class wb_dma_hol_test extends wb_dma_base_test;
        `uvm_component_utils(wb_dma_hol_test)
        function new(string name, uvm_component parent); super.new(name, parent); endfunction

        task run_phase(uvm_phase phase);
            wb_dma_hol_seq seq;
            phase.raise_objection(this);
            seq = wb_dma_hol_seq::type_id::create("seq");
            seq.model = model;
            seq.tot   = 16;
            seq.chunk = 4;
            seq.start(env.agent.sqr);

            env.sb.check_copy(0, seq.SW_SRC, 0, seq.SW_DST, seq.tot);   // ch0 (SW)
            env.sb.check_copy(0, seq.HS_SRC, 0, seq.HS_DST, seq.tot);   // ch1 (HS)
            env.sb.check_done_count(2);
            `uvm_info("HOL", "stalled HS channel did not starve the SW channel", UVM_LOW)

            phase.drop_objection(this);
        endtask
    endclass

    // ---- throughput / performance sequence -----------------------------------
    // Repeatedly runs a single-channel block copy (channel 0, one chunk) back to
    // back, WITHOUT scoreboard checks, until a wall-clock target elapses. Counts
    // completed transfers + words so the test can report throughput. Registers are
    // re-programmed every transfer (the engine writes back TXSZ/ADRx on completion)
    // -- a realistic per-transfer driver loop.
    class wb_dma_perf_seq extends wb_dma_base_seq;
        `uvm_object_utils(wb_dma_perf_seq)
        int  tot  = 256;                 // words per transfer
        real secs = 5.0;                 // wall-clock target (>= this runs)
        // results (read by the test after start()):
        longint unsigned xfers = 0;
        longint unsigned words = 0;
        real             wall  = 0.0;

        function new(string name = "wb_dma_perf_seq"); super.new(name); endfunction

        task body();
            logic [31:0] v;
            real t0;
            model.mem(0).fill(SRC_BASE, tot, 16'hBEEF);   // src content (once)
            reg_write(REG_INT_MASKA, 32'hffff_ffff);
            t0 = wc_now();
            forever begin
                reg_write(CH_TXSZ(0), mk_sz(0, tot));      // chunk=0 => single chunk
                reg_write(CH_ADR0(0), SRC_BASE);
                reg_write(CH_ADR1(0), DST_BASE);
                reg_write(CH_CSR(0),  mk_csr(.ch_en(1), .src_sel(0), .dst_sel(0),
                                             .inc_src(1), .inc_dst(1), .mode_hs(0),
                                             .ars(0), .prio(3'd0), .ine_done(1)));
                wait_int(REG_INT_SRCA, 32'h1, v);          // wait done + ack (clear)
                xfers++; words += tot;
                // Check the clock every 8 transfers (amortise the /proc read).
                if ((xfers % 8 == 0) && (wc_now() - t0) >= secs) break;
            end
            wall = wc_now() - t0;
        endtask
    endclass

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
            seq.start(env.agent.sqr);
            `uvm_info("PERF", $sformatf(
                "[%s] words/xfer=%0d  xfers=%0d  words=%0d  wall=%0.3f s  =>  %0.1f xfers/s  %0.3f Mword/s (%0.2f MB/s)",
                label, tot, seq.xfers, seq.words, seq.wall,
                real'(seq.xfers)/seq.wall,
                (real'(seq.words)/seq.wall)/1.0e6,
                (real'(seq.words)*4.0/seq.wall)/1.0e6), UVM_LOW)
            phase.drop_objection(this);
        endtask
    endclass
endpackage
