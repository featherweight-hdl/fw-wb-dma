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
