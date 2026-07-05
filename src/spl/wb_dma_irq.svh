// Interrupt propagation -- the model component that turns the DMA's interrupt
// state into the two aggregate level outputs. It lives INSIDE the model (a child
// of wb_dma) and knows only the abstract gpio_drive_if edge (from fw.proto.gpio's
// API layer) -- never a transactor; the signal-level GPIO initiator is instanced
// only at the wb_dma_spl module boundary and bound to irq_a/irq_b there.
//
// LEVELS vs CAUSES. The engine's de.irq port publishes per-channel CAUSES to an
// optional external scoreboard (spec/design-doc split). The two LEVEL outputs are
// a separate concern: inta = |(INT_SRC & INT_MSK_A), intb = |(INT_SRC & INT_MSK_B)
// (spec S4.2-4.3), evaluated by rf.inta()/intb(). This block owns the levels and
// is driven entirely off rf -- it does NOT consume de.irq, so de.irq stays free
// for a cause scoreboard.
//
// That level expression moves on exactly three events, all of which reach rf and
// are published on its wb_dma_int_if seam (int_changed) -- this block's single
// wake source:
//   * the engine flagged an irq-worthy event  (rf.raise_int -> a source is SET),
//   * an INT_MSK_A/B write                     (re-routes the aggregate), and
//   * a channel-CSR read                       (read-to-clear -> the deassert half).
// int_changed() only WAKES (sets m_dirty); the aggregate is read ONCE, in run(),
// from rf -- so the masking lives in exactly one place. wait(m_dirty) is level-
// sensitive, so a wake landing between evaluate and wait is not lost.
//
// The level outputs are OPTIONAL: an integration that consumes only causes (the
// raw-model smoke/perf benches) leaves irq_a/irq_b unbound, and run() is inert.
class wb_dma_irq extends fw_component
        implements wb_dma_int_if, fw_runnable;
    wb_dma_rf                     m_rf;
    fw_port #(gpio_drive_if #(1)) m_a, m_b;    // the model's irq_a / irq_b outputs
    bit                           m_dirty;      // a watched event occurred

    function new(string name, fw_component parent, wb_dma_rf rf,
                 fw_port #(gpio_drive_if #(1)) a, fw_port #(gpio_drive_if #(1)) b);
        super.new(name, parent);
        m_rf = rf; m_a = a; m_b = b;
        parent.add_runnable(this);
    endfunction

    // rf interrupt-state seam: a source was set (engine), a mask was written, or a
    // CSR read cleared a source. Any of these may move the level -- wake and let
    // run() re-evaluate. Non-blocking (a sink may not block).
    virtual function void int_changed(bit inta, bit intb);  m_dirty = 1'b1;  endfunction

    // Drive the two aggregate levels whenever an event may have moved them. set()
    // blocks a clock (registered onto inta_o/intb_o by the GPIO cores), so drive
    // only on an actual change to avoid consuming clocks on spurious wakes.
    virtual task run();
        gpio_drive_if #(1) da, db;
        bit a = 1'b0, b = 1'b0;
        if (!m_a.is_connected() || !m_b.is_connected())
            return;                                    // levels not exposed here
        da = m_a.get_if();
        db = m_b.get_if();
        da.set(1'b0); db.set(1'b0);                    // seat the reset level
        forever begin
            automatic bit na, nb;
            wait (m_dirty);                            // level-sensitive: no lost wake
            m_dirty = 1'b0;                            // clear BEFORE reading -> a change
            na = m_rf.inta();                          // signalled after this re-dirties
            nb = m_rf.intb();
            if (na !== a || nb !== b) begin
                a = na; b = nb;
                da.set(a); db.set(b);
            end
        end
    endtask
endclass
