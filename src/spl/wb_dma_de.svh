// DMA engine / data mover -- the one runnable in the model. It owns the engine's
// EDGE ports (two master memory interfaces + the interrupt sink + per-channel HW
// handshake) and runs the service loop: pick a ready channel, transfer one chunk
// through the fw_mem_if master ports, update the channel's working/status state,
// and raise interrupts. One pass services one chunk and then re-arbitrates (spec
// §3.2.1/§3.2.2 per-chunk re-arbitration).
//
// Arbitration is register-centric: readiness and priority come straight from the
// channel CSR fields (busy/stop/err/prio) plus the global PAUSE, so the engine
// arbitrates locally -- no separate arbiter object. An HW-handshake channel is
// additionally gated on a pending request: it is "ready" only once its device has
// asserted dma_req, so a stalled HS device never blocks service of other channels
// (no head-of-line blocking -- the engine never commits to a channel it would
// then block inside).
//
// When nothing is ready the engine does not spin on a delay. It names the set of
// things it waits on as one `fw_event_set` (m_wake) -- a HETEROGENEOUS set of
// `fw_awaitable_if` event sources: every CSR (a host write produces into it) plus
// every connected HS port (a dma_req produces into it). The wait site is simply
// m_wake.wait_any() (a single @event, O(1)). Sources PUSH their "event occurred"
// into the set, so there is no per-wait fork; this produce/monitor split is what
// lowers to RTL (the set's event is the OR of its members' fired pulses, and the
// wait site is a process sensitive to it).
//
// The engine speaks the Wishbone access API (wb_proto_if) on its master ports;
// the signal-level transactors at the module boundary bridge that to WB pins.
class wb_dma_de extends fw_component implements fw_runnable;
    wb_dma_rf         rf;
    wb_dma_hs_if      m_hs[];     // resolved per-channel HS handles (null = unconnected)
    int unsigned      last_ch;    // round-robin pointer (last channel serviced)
    // Loosely-timed temporal-decoupling keeper (null unless the data path uses
    // one, i.e. the TLM flavour). The engine does NOT generate time; the memories
    // ACCOUNT their data-availability delays into it, and the engine only FLUSHES
    // (sync) that accumulated real delay at its re-arbitration synchronization
    // point -- where it must observe the latest register state (CPU channel arming).
    fw_quantum_keeper qk;

    // Edge ports.
    fw_port #(wb_proto_if #(32, 32)) mif0, mif1;   // WISHBONE IF0 / IF1 masters (data)
    fw_port #(wb_dma_irq_if)  irq;          // interrupt-cause sink
    fw_port #(wb_dma_hs_if)   hs[];         // per-channel HW handshake

    // `fw_component_type_begin(wb_dma_de)
    // `fw_component_type_end


    function new(string name, fw_component parent, wb_dma_rf rf);
        super.new(name, parent);
        this.rf = rf;
        parent.add_runnable(this);          // active component: opt in to run()
    endfunction

    function void build();
        mif0 = new("mif0", this);
        mif1 = new("mif1", this);
        irq  = new("irq",  this);
        hs   = new[rf.n_ch];
        foreach (hs[i]) hs[i] = new($sformatf("hs%0d", i), this);
        m_hs = new[rf.n_ch];
        last_ch = 0;
    endfunction

    // ---- service loop --------------------------------------------------------
    virtual task run();
        wb_proto_if #(32, 32) if0 = mif0.get_if();
        wb_proto_if #(32, 32) if1 = mif1.get_if();
        fw_event_set      m_wake;     // re-arbitrate: a watched CSR write OR an HS request

        // de.irq is an OPTIONAL cause seam (like the hs[] ports): resolve it only
        // when a scoreboard is connected; raise() null-guards it. The interrupt
        // LEVELS do not depend on it -- they flow through rf.raise_int below.
        wb_dma_irq_if  irqif = irq.is_connected() ? irq.get_if() : null;

        // Collect the heterogeneous wait list -- every CSR plus every connected HS
        // port -- into the wake set. Each entry is just an fw_awaitable_if; the loop
        // is source-agnostic.
        m_wake = new();
        m_wake.add(rf.regs.csr);                            // global CSR (PAUSE)
        foreach (rf.ch[i]) m_wake.add(rf.ch[i].regs.csr);
        foreach (hs[i]) if (hs[i].is_connected()) begin
            m_hs[i] = hs[i].get_if();                       // also cache for has_req()
            m_wake.add(m_hs[i]);
        end

        // `fw_trace_loop_begin("service")           // one iteration per arbitration round
        forever begin
            automatic int c;
            // Flush accumulated data-availability delays BEFORE re-arbitrating, so
            // the engine observes the latest register state (the CPU's channel
            // arming) at this synchronization point. This is NOT time generation:
            // the flushed time IS the sum of the just-serviced chunk's data delays.
            if (qk != null) qk.sync();
            c = next();
            // `fw_trace_point_begin("arb")          // outcome of this round
              // `fw_trace_param_int(c)              //   winner (-1 == nothing ready)
              // `fw_trace_param_int(last_ch)        //   round-robin pointer
              // `fw_trace_cond("paused", rf.paused())
            // `fw_trace_point_end
            if (c < 0) begin
                m_wake.wait_any();           // sleep until a CSR write or an HS request
                continue;
            end
            service_chunk(c, if0, if1, irqif);
        end
        // `fw_trace_loop_end("service")
    endtask

    // ---- register-centric arbitration (spec §3.1) ----------------------------
    // A channel is ready when it is busy (armed/loaded, the CSR status bit) and
    // neither stopped nor errored. An HW-handshake channel is ALSO gated on a
    // pending dma_req, so the engine never picks (and then blocks on) an HS
    // channel whose device has not yet requested a chunk.
    local function bit ready(int i);
        wb_dma_csr_t csr = rf.ch[i].regs.csr.read();
        if (!csr.busy || csr.stop || csr.err) return 1'b0;
        if (!csr.mode) return 1'b1;                   // SW channel: ready
        if (m_hs[i] == null) return 1'b0;             // HS channel needs a device...
        return m_hs[i].has_req();                     // ...and a pending request
    endfunction

    function int prio_of(int i);  return int'(rf.ch[i].regs.csr.read().prio);  endfunction

    // Index of the next channel to service, or -1 if none (or globally paused):
    // highest CSR priority first, then round-robin among equal-priority readies.
    local function int next();
        int n = rf.n_ch;
        int best_pri = -1;

        // `fw_trace_enter("next")

        if (rf.paused()) return -1;
        foreach (rf.ch[i])
            if (ready(i) && prio_of(i) > best_pri)
                best_pri = prio_of(i);
        if (best_pri < 0) return -1;
        for (int k = 1; k <= n; k++) begin
            int idx = (last_ch + k) % n;
            if (ready(idx) && prio_of(idx) == best_pri) begin
                last_ch = idx;
                // `fw_trace_leave_begin("next")
                  // `fw_trace_return_int(idx)
                // `fw_trace_leave_end
                return idx;
            end
        end

        // `fw_trace_leave_begin("next")
          // `fw_trace_return_int(-1)
        // `fw_trace_leave_end
        return -1;
    endfunction

    // Transfer one chunk of channel c (CHK_SZ words, or all of TOT_SZ when
    // CHK_SZ==0), then settle the channel (chunk-int / done / ARS / error).
    local task automatic service_chunk(int c,
                                       wb_proto_if #(32, 32) if0, wb_proto_if #(32, 32) if1,
                                       wb_dma_irq_if irqif);
        wb_dma_ch    ch  = rf.ch[c];
        wb_dma_csr_t csr = ch.regs.csr.read();           // config snapshot for this chunk
        wb_dma_sz_t  sz  = ch.regs.sz.read();
        automatic bit nd = 0, rest = 0;
        automatic int n;

        // `fw_trace_enter_begin("service_chunk")
          // `fw_trace_param_int(c)
        // `fw_trace_enter_end

        // HW-handshake mode: consume the chunk request the arbiter gated on (it is
        // already pending -- ready() required has_req() -- so wait_req returns at
        // once), latching its nd/rest qualifiers.
        if (csr.mode) begin
            m_hs[c].wait_req(nd, rest);
            if (rest && csr.rest_en) ch.load_working();
        end

        n = (sz.chk_sz == 0) ? ch.w_rem : min2(int'(sz.chk_sz), ch.w_rem);
        ch.set_busy(1'b1);

        // The engine NEVER advances time itself -- it is a pure data mover. All
        // timing emerges from data-availability delays on the master access()
        // calls (the memory / bus paces each word). Those delays are quantum-
        // decoupled on the TLM path (see wb_dma_mem), so the account is cheap.

        // `fw_trace_point_begin("plan")                 // chunk parameters, resolved
          // `fw_trace_param_int(n)                      //   words this chunk will move
          // `fw_trace_param_uint(sz.chk_sz)             //   CHK_SZ (0 == whole transfer)
          // `fw_trace_param_uint(ch.w_rem)              //   words left before this chunk
          // `fw_trace_cond("hs_mode", csr.mode)         //   SW (0) vs HW-handshake (1)
        // `fw_trace_point_end

        // `fw_trace_loop_begin("xfer")                  // one iteration per word moved
        for (int i = 0; i < n; i++) begin
            automatic bit [31:0] data;
            automatic bit        berr;
            if (swptr_stall(ch)) begin
                // `fw_trace_cond("swptr_stall", 1'b1)   // FIFO backpressure (§3.5)
                break;                                // stop at software ptr
            end
            begin
                automatic bit [31:0] wdr;   // write response data (ignored)
                wb_proto_if #(32, 32) src = csr.src_sel ? if1 : if0;
                wb_proto_if #(32, 32) dst = csr.dst_sel ? if1 : if0;
                // `fw_trace_point_begin("word")         // per-beat working state
                  // `fw_trace_param_int(i)
                  // `fw_trace_param_uint(ch.w_src)      //   source address this beat
                  // `fw_trace_param_uint(ch.w_dst)      //   dest address this beat
                // `fw_trace_point_end
                src.access(ch.w_src, 32'h0, 4'hf, 1'b0, data, berr);   // read
                if (berr) begin /* `fw_trace_cond("berr_rd", 1'b1) */ fail(ch, irqif); return; end
                dst.access(ch.w_dst, data, 4'hf, 1'b1, wdr, berr);     // write
                if (berr) begin /* `fw_trace_cond("berr_wr", 1'b1) */ fail(ch, irqif); return; end
            end
            if (csr.inc_src) ch.advance_src();
            if (csr.inc_dst) ch.advance_dst();
            ch.w_rem--;
            // STOP is host-writable mid-transfer, so read it fresh (§4.4.1).
            if (ch.regs.csr.read().stop) begin
                // `fw_trace_cond("host_stop", 1'b1)
                fail(ch, irqif); return;
            end
        end
        // `fw_trace_loop_end("xfer")

        if (csr.mode) begin
            m_hs[c].ack();                               // acknowledge the chunk (§3.8)
        end

        // More chunks remain in this transfer: optional chunk interrupt, then
        // re-arbitrate (return to the loop).
        if (sz.chk_sz != 0 && ch.w_rem != 0) begin
            // `fw_trace_point_begin("chunk_more")          // chunk boundary, transfer continues
              // `fw_trace_param_uint(ch.w_rem)
              // `fw_trace_cond("int", csr.ine_chk_done)
            // `fw_trace_point_end
            if (csr.ine_chk_done) raise(ch, c, CAUSE_CHUNK, irqif);
            return;
        end

        // TOT_SZ exhausted -> transfer complete. ARS is capability-gated (App. A).
        if ((ch.cap_ars & csr.ars) && !ch.regs.csr.read().stop) begin
            // `fw_trace_cond("auto_restart", 1'b1)         // ARS: reload and keep going (§3.2.1)
            ch.load_working();
        end else begin
            ch.set_busy(1'b0); ch.set_done(1'b1);
            ch.clr_en();                                 // HW clears CH_EN on done
            // `fw_trace_cond("done", 1'b1)                 // transfer complete
            if (csr.ine_done) raise(ch, c, CAUSE_DONE, irqif);
        end

        // `fw_trace_leave("service_chunk");

    endtask

    // Abort the channel with an error (bus error or host STOP).
    local task fail(wb_dma_ch ch, wb_dma_irq_if irqif);
        ch.clr_stop();
        ch.set_busy(1'b0); ch.set_err(1'b1);
        ch.clr_en();                                     // HW clears CH_EN on error
        if (ch.regs.csr.read().ine_err) raise(ch, int'(ch.id), CAUSE_ERR, irqif);
    endtask

    // Latch the interrupt source and publish the cause.
    local task raise(wb_dma_ch ch, int c, wb_dma_cause_e cause,
                     wb_dma_irq_if irqif);
        case (cause)
            CAUSE_CHUNK: ch.set_int_chunk();
            CAUSE_DONE:  ch.set_int_done();
            CAUSE_ERR:   ch.set_int_err();
            default: ;
        endcase
        rf.raise_int(c);                                 // moves the level (rf int seam)
        if (irqif != null)                               // publish the cause (optional sink)
            irqif.raise('{channel: c[4:0], cause: cause});
    endtask

    // FIFO software-pointer stall (§3.5): the address bound for IF0 may not cross
    // the enabled software pointer. Approximate: compare the IF0-side working
    // address (whichever of src/dst targets IF0) to the pointer.
    local function bit swptr_stall(wb_dma_ch ch);
        bit [31:0]   ptr, a0;
        bit [31:0]   sp  = ch.regs.swptr.read();
        wb_dma_csr_t csr = ch.regs.csr.read();
        if (!sp[31]) return 1'b0;                        // SWPTR_EN
        ptr = sp & 32'h7fff_fffc;
        if (csr.src_sel == 1'b0)      a0 = ch.w_src;
        else if (csr.dst_sel == 1'b0) a0 = ch.w_dst;
        else                          return 1'b0;       // neither side on IF0
        return (a0 & 32'h7fff_fffc) == ptr;
    endfunction

    local function int min2(int a, int b); return (a < b) ? a : b; endfunction
endclass
