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
