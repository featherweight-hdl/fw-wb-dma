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

        model.irqc.reset();
        preload(src_sel, SRC_BASE, tot, 16'hC0DE);   // fan out to DUT + reference

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
