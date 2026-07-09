// ======================================================================
// Wishbone-backed model for the wb_dma UVM environment.
//
// Same abstract surface as the TLM model (wb_dma_model_base), but the DMA engine
// lives INSIDE the signal-level wb_dma_spl wrapper (instanced by the SV top). This
// class holds only the BUS-SIDE peers, wired through fw-proto-wb transactors:
//   - rf_if(): a host wb_mem_initiator adapter that drives a Wishbone initiator
//     into wb_dma_spl's WB0 slave (register access becomes real WB cycles);
//   - s0/s1: the two data memories, backed behind Wishbone target transactors on
//     wb_dma_spl's WB0/WB1 master ports (data movement becomes real WB cycles),
//     while keeping the wb_dma_mem fill/peek backdoor the scoreboard uses;
//   - irqc: filled from INT_SRC register reads (note_int_src), not from an engine
//     callback -- the engine's irq is internal to the wrapper.
//
// The SV top seats the transactor virtual interfaces before start() and forks the
// two memory-target service loops (connect() is a function, cannot start a task).
//
// One class per .svh, included below in dependency order.
// ======================================================================
`include "uvm_macros.svh"

package wb_dma_wb_model_pkg;
    import fw_hdl_pkg::*;
    import fw_std_pkg::*;
    import fw_proto_wb_pkg::*;         // wb_proto_if, xtor bridges, wb_mem_* adapters
    import wb_dma_model_pkg::*;        // base + wb_dma_mem + wb_dma_irq_collector
    import uvm_pkg::*;
    import wb_dma_ref_model_pkg::*;    // wb_dma_ref_model (comparison reference)
    import wb_dma_uvm_pkg::*;          // wb_dma_env / wb_dma_scoreboard
    import fwvip_gpio_pkg::*;          // fwvip_gpio_monitor + fwvip_gpio_transaction
    import fwvip_wb_pkg::*;            // fwvip_wb_target agent + fwvip_wb_target_config_ap

    `include "wb_dma_wb_model.svh"
    `include "wb_dma_int_gpio_sub.svh"
    `include "wb_dma_wb_env.svh"
    `include "wb_dma_wbxtor_env.svh"
endpackage
