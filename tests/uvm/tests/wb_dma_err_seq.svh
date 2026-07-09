// ---- single-channel bus-error abort sequence ------------------------------
// Programs a single-channel block copy, but arms an injected bus error on the
// source read of word `err_word`. The engine moves words 0..err_word-1, then
// the read of word err_word terminates with ERR -> the channel aborts (CH_ERR)
// and, with ine_err set, raises its interrupt. Both the DUT and the always-on
// reference get the SAME injected error (fanned out via inject_err), so both
// abort at the identical beat -- the cross-comparator checks their master
// streams and error counts match.
class wb_dma_err_seq extends wb_dma_base_seq;
    `uvm_object_utils(wb_dma_err_seq)
    bit src_sel  = 0;
    bit dst_sel  = 0;
    int tot      = 16;
    int chunk    = 4;
    int err_word = 6;      // abort on the source read of this word

    function new(string name = "wb_dma_err_seq"); super.new(name); endfunction

    task body();
        logic [31:0] v;
        model.irqc.reset();
        ensure_ref();
        if (ref_model != null) ref_model.irqc.reset();
        preload(src_sel, SRC_BASE, tot, 16'hE00D);
        inject_err(src_sel, SRC_BASE + 4*err_word);   // source read of word err_word -> ERR

        reg_write(REG_INT_MASKA, 32'hffff_ffff);
        reg_write(CH_TXSZ(0), mk_sz(chunk, tot));
        reg_write(CH_ADR0(0), SRC_BASE);
        reg_write(CH_ADR1(0), DST_BASE);
        reg_write(CH_CSR(0),  mk_csr(.ch_en(1), .src_sel(src_sel), .dst_sel(dst_sel),
                                     .inc_src(1), .inc_dst(1), .mode_hs(0), .ars(0),
                                     .prio(3'd0), .ine_done(1), .ine_err(1)));

        // The error raises the channel's interrupt (same INT_SRC bit as done).
        wait_int(REG_INT_SRCA, 32'h1, v);
        if (!v[0])
            `uvm_error("ERR", "channel 0 error interrupt never observed")
    endtask
endclass
