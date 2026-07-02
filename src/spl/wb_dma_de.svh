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
// The engine speaks fw_mem_if (read/write), never Wishbone; the bus protocol is
// supplied by adapters/transactors at the module boundary.
class wb_dma_de extends fw_component implements fw_runnable;
    wb_dma_rf         rf;
    wb_dma_hs_if      m_hs[];     // resolved per-channel HS handles (null = unconnected)
    fw_event_set      m_wake;     // re-arbitrate: a watched CSR write OR an HS request
    int unsigned      last_ch;    // round-robin pointer (last channel serviced)

    // Edge ports.
    fw_port #(fw_mem_if #(logic [31:0], logic [31:0], logic [3:0])) mif0, mif1;   // WISHBONE IF0 / IF1 masters (data)
    fw_port #(wb_dma_irq_if)  irq;          // interrupt-cause sink
    fw_port #(wb_dma_hs_if)   hs[];         // per-channel HW handshake

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
        fw_mem_if #(logic [31:0], logic [31:0], logic [3:0]) if0 = mif0.get_if();
        fw_mem_if #(logic [31:0], logic [31:0], logic [3:0]) if1 = mif1.get_if();
        wb_dma_irq_if  irqif = irq.get_if();

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

        forever begin
            automatic int c = next();
            if (c < 0) begin
                m_wake.wait_any();           // sleep until a CSR write or an HS request
                continue;
            end
            service_chunk(c, if0, if1, irqif);
        end
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
        if (rf.paused()) return -1;
        foreach (rf.ch[i])
            if (ready(i) && prio_of(i) > best_pri)
                best_pri = prio_of(i);
        if (best_pri < 0) return -1;
        for (int k = 1; k <= n; k++) begin
            int idx = (last_ch + k) % n;
            if (ready(idx) && prio_of(idx) == best_pri) begin
                last_ch = idx;
                return idx;
            end
        end
        return -1;
    endfunction

    // Transfer one chunk of channel c (CHK_SZ words, or all of TOT_SZ when
    // CHK_SZ==0), then settle the channel (chunk-int / done / ARS / error).
    local task automatic service_chunk(int c,
                                       fw_mem_if #(logic [31:0], logic [31:0], logic [3:0]) if0, fw_mem_if #(logic [31:0], logic [31:0], logic [3:0]) if1,
                                       wb_dma_irq_if irqif);
        wb_dma_ch    ch  = rf.ch[c];
        wb_dma_csr_t csr = ch.regs.csr.read();           // config snapshot for this chunk
        wb_dma_sz_t  sz  = ch.regs.sz.read();
        automatic bit nd = 0, rest = 0;
        automatic int n;

        // HW-handshake mode: consume the chunk request the arbiter gated on (it is
        // already pending -- ready() required has_req() -- so wait_req returns at
        // once), latching its nd/rest qualifiers.
        if (csr.mode) begin
            m_hs[c].wait_req(nd, rest);
            if (rest && csr.rest_en) ch.load_working();
        end

        n = (sz.chk_sz == 0) ? ch.w_rem : min2(int'(sz.chk_sz), ch.w_rem);
        ch.set_busy(1'b1);

        for (int i = 0; i < n; i++) begin
            automatic bit [31:0] data;
            automatic bit        berr;
            if (swptr_stall(ch)) break;                  // FIFO: stop at software ptr (§3.5)
            begin
                fw_mem_if #(logic [31:0], logic [31:0], logic [3:0]) src = csr.src_sel ? if1 : if0;
                fw_mem_if #(logic [31:0], logic [31:0], logic [3:0]) dst = csr.dst_sel ? if1 : if0;
                src.read(data, berr, ch.w_src);
                if (berr) begin fail(ch, irqif); return; end
                dst.write(berr, ch.w_dst, data, 4'hf);
                if (berr) begin fail(ch, irqif); return; end
            end
            if (csr.inc_src) ch.advance_src();
            if (csr.inc_dst) ch.advance_dst();
            ch.w_rem--;
            // STOP is host-writable mid-transfer, so read it fresh (§4.4.1).
            if (ch.regs.csr.read().stop) begin fail(ch, irqif); return; end
        end

        if (csr.mode) begin
            m_hs[c].ack();                               // acknowledge the chunk (§3.8)
        end

        // More chunks remain in this transfer: optional chunk interrupt, then
        // re-arbitrate (return to the loop).
        if (sz.chk_sz != 0 && ch.w_rem != 0) begin
            if (csr.ine_chk_done) raise(ch, c, CAUSE_CHUNK, irqif);
            return;
        end

        // TOT_SZ exhausted -> transfer complete. ARS is capability-gated (App. A).
        if ((ch.cap_ars & csr.ars) && !ch.regs.csr.read().stop) begin
            ch.load_working();                           // auto-restart (§3.2.1)
        end else begin
            ch.set_busy(1'b0); ch.set_done(1'b1);
            ch.clr_en();                                 // HW clears CH_EN on done
            if (csr.ine_done) raise(ch, c, CAUSE_DONE, irqif);
        end
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
        rf.raise_int(c);
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
