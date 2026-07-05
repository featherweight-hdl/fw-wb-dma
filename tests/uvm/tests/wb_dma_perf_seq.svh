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
