// Behavioral (class-based) model of the WISHBONE DMA/Bridge engine -- the "spl"
// model. One package holds the whole class layer: the DMA-specific types, the two
// DMA APIs, and the model components (one .svh per class, included below). The
// signal-level module wrapper (wb_dma_spl, ports matching wb_dma_top) lives in a
// separate compilation unit (wb_dma_spl.sv) and brings in the Wishbone kit; this
// core-model package does NOT depend on Wishbone.
//
// Bus access is protocol-independent: the engine speaks fw_mem_if (from fw-hdl's
// fw_std_pkg); Wishbone is reached only via the fw-proto-wb transactors +
// fw_mem_if adapters, wired at the wb_dma_spl boundary. There is no dedicated
// types package -- the few shared types are declared directly here (behavioral
// model, so no synthesizable-sharing constraint).
//
// Package dependency: fw_hdl_pkg (modeling-library kernel) and fw_std_pkg (the
// std protocol layer, which provides fw_mem_if). Both ship in fw-hdl.
`include "fw_hdl_macros.svh"
`include "wb_dma_spl_macros.svh"     // also pulls in fw_std_macros.svh (FW_MEM_IMP)

package wb_dma_spl_pkg;
    import fw_hdl_pkg::*;
    import fw_std_pkg::*;           // fw_mem_if (protocol-independent memory API)
    export fw_std_pkg::*;           // re-export so consumers see fw_mem_if too

    // ---- shared types (no dedicated types package) ---------------------------
    // Interrupt cause delivered through wb_dma_irq_if.
    typedef enum bit [1:0] { CAUSE_CHUNK, CAUSE_DONE, CAUSE_ERR } wb_dma_cause_e;

    // One interrupt event: which channel and why.
    typedef struct packed {
        bit [4:0]      channel;
        wb_dma_cause_e cause;
    } wb_dma_irq_evt_t;

    // ---- MMIO field layouts (2-state packed structs, MSB-first; spec Tables 6/7)
    // These are the typed faces of the channel registers, consumed by the fw-hdl
    // register model (`fw_reg #(T)`): a named field is just a slice of T, so the
    // host programs and the engine inspects bits by name (r.read().ch_en) with no
    // hand-maintained bit offsets. Bit positions match the OpenCores wb_dma RTL.
    typedef struct packed {
        bit [8:0] reserved;       // 31:23 RO
        bit       int_chk_done;   // 22 ROC  (chunk-done interrupt source)
        bit       int_done;       // 21 ROC  (transfer-done interrupt source)
        bit       int_err;        // 20 ROC  (error interrupt source)
        bit       ine_chk_done;   // 19 RW   (chunk-done interrupt enable)
        bit       ine_done;       // 18 RW
        bit       ine_err;        // 17 RW
        bit       rest_en;        // 16 RW
        bit [2:0] prio;           // 15:13 RW
        bit       err;            // 12 RO   (status: errored)
        bit       done;           // 11 RO   (status: complete)
        bit       busy;           // 10 RO   (status: transferring)
        bit       stop;           //  9 WO   (host abort pulse)
        bit       sz_wb;          //  8 RW
        bit       use_ed;         //  7 RW   (external descriptor)
        bit       ars;            //  6 RW   (auto-restart)
        bit       mode;           //  5 RW   (1 = HW handshake)
        bit       inc_src;        //  4 RW
        bit       inc_dst;        //  3 RW
        bit       src_sel;        //  2 RW   (0 = IF0, 1 = IF1)
        bit       dst_sel;        //  1 RW
        bit       ch_en;          //  0 RW   (channel enable)
    } wb_dma_csr_t;

    typedef struct packed {
        bit [6:0]  reserved1;     // 31:25 RO
        bit [8:0]  chk_sz;        // 24:16 RW  (chunk size in words; 0 => whole TOT_SZ)
        bit [3:0]  reserved0;     // 15:12 RO
        bit [11:0] tot_sz;        // 11:0  RW  (total transfer size in words)
    } wb_dma_sz_t;

    // ---- DMA-specific APIs (each ships a `FW_WB_DMA_*_IMP macro) -------------
    `include "wb_dma_hs_if.svh"
    `include "wb_dma_irq_if.svh"
    `include "wb_dma_int_if.svh"      // interrupt-change notification seam

    // ---- model components (one class per file) -------------------------------
    `include "wb_dma_ch.svh"          // per-channel register bank + working set
    `include "wb_dma_rf.svh"          // register file + host fw_mem_if provider
    `include "wb_dma_de.svh"          // data-mover engine (runnable; inlines arbitration)
    `include "wb_dma.svh"             // top component (rf + de)
endpackage
