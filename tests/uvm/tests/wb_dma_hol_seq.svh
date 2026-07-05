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
