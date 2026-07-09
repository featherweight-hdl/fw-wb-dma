// ======================================================================
// UVM side of the wb_dma SPL environment.
//
//   * wb_dma_reg_item / _driver / _sequencer / _agent
//        a register-access agent over the ABSTRACT fw_mem_if BFM. Today the
//        BFM is the SPL engine's register export; the same agent would later
//        bind to a Wishbone transactor bridge for RTL sign-off (one testbench,
//        per the project's verification methodology).
//   * wb_dma_scoreboard
//        checks block-copy correctness (dst memory == source pattern) and the
//        per-channel done interrupts / completion order, reading the model's
//        memories + IRQ collector by backdoor (the bench's s0.mem[] compares).
//   * wb_dma_env
//        the reg agent + scoreboard, plus the model env handle.
//   * wb_dma_base_seq
//        register read/write helpers + CSR/SZ field builders + the channel
//        register map (matches the RTL: 0x20 base, 0x20 stride).
//
// One class per .svh, included below in dependency order. Scenario
// sequences/tests live in wb_dma_tests_pkg.
// ======================================================================
`include "uvm_macros.svh"

package wb_dma_uvm_pkg;
    import uvm_pkg::*;
    import fw_proto_wb_pkg::*;      // wb_proto_if (register-access seam / reg tee)
    import wb_dma_model_pkg::*;
    import wb_dma_ref_model_pkg::*; // always-on reference (wb_dma_ref_model, wb_dma_xact)
    import fwvip_wb_pkg::*;         // fwvip_wb_initiator agent + config + transaction

    // Wall-clock seconds from /proc/uptime (monotonic since boot, ~10 ms
    // resolution; DPI-free). Used by the tops and the perf test to measure
    // wall-clock runtime -- the delta between two calls is elapsed real time.
    function automatic real wc_now();
        int  fd;
        real up;
        up = 0.0;
        fd = $fopen("/proc/uptime", "r");
        if (fd == 0) return 0.0;
        void'($fscanf(fd, "%f", up));
        $fclose(fd);
        return up;
    endfunction

    // ---- register map (cf. packages/wb_dma/rtl wb_dma_defines.v) --------------
    localparam logic [31:0] REG_COR      = 32'h00;   // global CSR (bit0 = PAUSE)
    localparam logic [31:0] REG_INT_MASKA = 32'h04;
    localparam logic [31:0] REG_INT_MASKB = 32'h08;
    localparam logic [31:0] REG_INT_SRCA  = 32'h0c;  // read-only snapshot (clear via CH_CSR read)
    localparam logic [31:0] REG_INT_SRCB  = 32'h10;

    function automatic logic [31:0] CH_CSR (int c); return 32'h20 + 32'h20*c; endfunction
    function automatic logic [31:0] CH_TXSZ(int c); return 32'h24 + 32'h20*c; endfunction
    function automatic logic [31:0] CH_ADR0(int c); return 32'h28 + 32'h20*c; endfunction
    function automatic logic [31:0] CH_AM0 (int c); return 32'h2c + 32'h20*c; endfunction
    function automatic logic [31:0] CH_ADR1(int c); return 32'h30 + 32'h20*c; endfunction
    function automatic logic [31:0] CH_AM1 (int c); return 32'h34 + 32'h20*c; endfunction

    // Build a channel CSR word (bit positions match the RTL/spec).
    function automatic logic [31:0] mk_csr(bit ch_en, bit src_sel, bit dst_sel,
                                           bit inc_src, bit inc_dst, bit mode_hs,
                                           bit ars, logic [2:0] prio,
                                           bit ine_done = 1, bit ine_chunk = 0,
                                           bit ine_err = 0);
        logic [31:0] v = '0;
        v[0]  = ch_en;   v[1]  = dst_sel; v[2]  = src_sel;
        v[3]  = inc_dst; v[4]  = inc_src; v[5]  = mode_hs; v[6] = ars;
        v[15:13] = prio;
        v[17] = ine_err; v[18] = ine_done; v[19] = ine_chunk;
        return v;
    endfunction

    // SZ word: chunk in [24:16] (9b), tot in [11:0] (12b).
    function automatic logic [31:0] mk_sz(int chunk, int tot);
        return ((chunk & 32'h0000_01ff) << 16) | (tot & 32'h0000_0fff);
    endfunction

    // Register access uses the fwvip-wb initiator agent (fwvip_wb_initiator);
    // stimulus is fwvip_wb_transaction on its sequencer. The bespoke reg
    // item/driver/agent were retired now that the model's register port is a
    // native wb_proto_if the fwvip config binds to (see wb_dma_env / base_seq).
    `include "wb_dma_scoreboard.svh"
    `include "wb_dma_reg_tee.svh"
    `include "wb_dma_comparator.svh"
    `include "wb_dma_mon_adapter.svh"
    `include "wb_dma_reg_forward.svh"
    `include "wb_dma_env.svh"
    `include "wb_dma_base_seq.svh"
endpackage
