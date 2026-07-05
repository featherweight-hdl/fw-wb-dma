// ======================================================================
// RTL-flavour model for the wb_dma UVM environment.
//
// Same abstract surface as the TLM / WB models (wb_dma_model_base). The DMA
// engine is the OpenCores wb_dma_top RTL (instanced by the SV top). This model
// differs from wb_dma_wb_model in ONE way: the two data memories are backed by
// combinational, 0-wait-state SV RAMs (wb_ram_slv) that the DUT masters into
// directly -- NOT by FIFO-backed target transactors. The wb_dma engine is proven
// against a same-cycle memory (cf. wb_slv_model.v); a variable-latency transactor
// desynchronises its chunk/pointer write-back across the test's per-iteration
// re-programming. Everything else (host register path over a Wishbone initiator,
// interrupt observation via note_int_src + a GPIO monitor) is inherited unchanged.
//
// The SV top seats the host initiator vif (vhost) and the two RAM vifs (vram0/1)
// before start(); no memory-service task is forked (the RAMs are pure RTL).
//
// One class per .svh, included below in dependency order.
// ======================================================================
`include "uvm_macros.svh"

package wb_dma_rtl_model_pkg;
    import fw_hdl_pkg::*;
    import fw_std_pkg::*;
    import fw_proto_wb_pkg::*;
    import wb_dma_model_pkg::*;        // base + wb_dma_mem + wb_dma_irq_collector
    import uvm_pkg::*;
    import wb_dma_uvm_pkg::*;
    import wb_dma_wb_model_pkg::*;     // reuse wb_dma_wb_model (host path) + wb_dma_wb_env

    `include "wb_dma_ram_mem.svh"
    `include "wb_dma_rtl_model.svh"
endpackage
