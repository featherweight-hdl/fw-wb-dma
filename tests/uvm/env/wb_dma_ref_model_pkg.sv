// ======================================================================
// Reference-model package: the always-on passive SPL reference used by the
// SPL<->RTL comparison harness (see docs/wb_dma_spl_rtl_comparison_strategy.md
// and docs/wb_dma_spl_rtl_comparison_plan.md).
//
// It sits between the fw-hdl model package (wb_dma_model_pkg, no UVM) and the
// UVM env package (wb_dma_uvm_pkg): it needs the TLM model type from the former
// and uvm_object/analysis machinery from the latter, so it imports uvm_pkg here
// and is imported into wb_dma_uvm_pkg.
//
//   wb_dma_xact        -- canonical master-transaction record (comparison currency)
//   wb_dma_xact_sink   -- the receive seam the comparator implements
//   wb_dma_xact_tap    -- wb_proto_if decorator on the engine master ports
//   wb_dma_ref_model   -- TLM model + taps + channel attribution
//
// One class per .svh, included in dependency order.
// ======================================================================
`include "uvm_macros.svh"

package wb_dma_ref_model_pkg;
    import uvm_pkg::*;
    import fw_hdl_pkg::*;
    import fw_std_pkg::*;
    import fw_proto_wb_pkg::*;      // wb_proto_if
    import wb_dma_spl_pkg::*;       // wb_dma engine + wb_dma_csr_t / _sz_t
    import wb_dma_model_pkg::*;     // wb_dma_tlm_model, wb_dma_mem_if_t, wb_dma_model_base

    `include "wb_dma_xact.svh"
    `include "wb_dma_xact_tap.svh"
    `include "wb_dma_ref_model.svh"
endpackage
