// ---- base sequence: register helpers -------------------------------------
// Runs on the fwvip-wb initiator sequencer (fwvip_wb_transaction). Its config,
// bound over the model's wb_proto_if register port, turns each transaction into
// a design access() -- direct method call for TLM, real WB cycles for the
// signal-level DUTs.
class wb_dma_base_seq extends uvm_sequence #(fwvip_wb_transaction);
    `uvm_object_utils(wb_dma_base_seq)
    wb_dma_model_base model;     // set by the test before start (backdoor access)

    function new(string name = "wb_dma_base_seq"); super.new(name); endfunction

    task reg_write(logic [31:0] addr, logic [31:0] data);
        fwvip_wb_transaction t = fwvip_wb_transaction::type_id::create("t");
        start_item(t);
        t.we = 1'b1; t.adr = addr; t.dat = data; t.sel = 4'hf;
        finish_item(t);
    endtask

    task reg_read(logic [31:0] addr, output logic [31:0] data);
        fwvip_wb_transaction t = fwvip_wb_transaction::type_id::create("t");
        start_item(t);
        t.we = 1'b0; t.adr = addr; t.sel = 4'hf;
        finish_item(t);
        data = t.dat;
        // Bus-observed interrupt sources -> model (was the reg driver's job; the
        // WB/RTL flavours record done order/count from these, TLM is a no-op).
        if (addr[11:0] == REG_INT_SRCA[11:0]) model.note_int_src(1'b0, data);
        if (addr[11:0] == REG_INT_SRCB[11:0]) model.note_int_src(1'b1, data);
    endtask

    // Interrupt-driven, source-agnostic waits. These depend ONLY on the model's
    // interrupt-change seam (wait_int_change / *_level, signalled by whichever
    // producer is active -- rf.signal_int for TLM, a GPIO monitor for the xtor/
    // RTL paths) plus register reads for identity. No `#delay` polling and no
    // backdoor into the model -- so the identical code runs for all three DUT
    // flavours. The line LEVEL (persistent) drives the decision; the change
    // event only wakes us, so an assertion during a bus read is never missed.
    // A stuck line hangs until the top-level TB $fatal timeout (loud failure).

    // Acknowledge (clear) the interrupt of every channel flagged in `srcbits`
    // by reading its CSR. This is how the wb_dma HARDWARE clears a channel's
    // interrupt source (reading CH_CSR asserts the RF's ch_csr_re read strobe);
    // INT_SRC_A/B themselves are read-only snapshots on the RTL. The TLM/SPL
    // model clears its pending vector on the INT_SRC read instead, so the CSR
    // read is a harmless no-op there -- keeping this service routine identical
    // across all three DUT flavours (as a real driver's ISR would be written).
    task ack_int(logic [31:0] srcbits);
        logic [31:0] d;
        for (int c = 0; c < 31; c++)
            if (srcbits[c]) reg_read(CH_CSR(c), d);
    endtask

    // Wait until `mask` bits are set in the given INT_SRC register, then ack the
    // signalled channel(s) so the (level-based) interrupt line deasserts.
    task wait_int(logic [31:0] src_off, logic [31:0] mask, output logic [31:0] val);
        bit bank = (src_off == REG_INT_SRCB);
        val = '0;
        forever begin
            reg_read(src_off, val);
            if (|(val & mask)) break;
            while (!(bank ? model.intb_level() : model.inta_level()))
                model.wait_int_change();     // sleep until this bank's line asserts
        end
        ack_int(val & mask);
    endtask

    // Block until `n` done interrupts have been reported. Reads INT_SRC on each
    // asserted interrupt (the reg driver's note_int_src records completions for
    // the WB/RTL flavours; the engine fills irqc for TLM), then acks the flagged
    // channels so each completion is counted exactly once and the line clears.
    task wait_done(int n);
        logic [31:0] va, vb;
        forever begin
            reg_read(REG_INT_SRCA, va);   // driver's note_int_src records dones
            reg_read(REG_INT_SRCB, vb);
            ack_int(va | vb);             // clear so they are not re-counted
            if (model.irqc.n_done >= n) break;
            while (!model.inta_level() && !model.intb_level())
                model.wait_int_change();     // sleep until some line asserts
        end
    endtask
endclass
