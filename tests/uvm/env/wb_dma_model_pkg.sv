// ======================================================================
// Model-side bring-up for the wb_dma SPL UVM environment.
//
// This is the fw-hdl (class-model) "DUT" side: the wb_dma engine wired to two
// fw_mem_if memories (IF0=s0, IF1=s1, mirroring the reference bench's two WB
// slaves), an interrupt-cause collector, and one HW-handshake device per
// channel. None of this is UVM -- it is the fw-hdl component tree the UVM env
// reaches through the protocol-independent fw_mem_if BFM (engine register
// slave) and a handful of backdoor handles (memories, IRQ collector, HS devices).
//
// Scenario shape is taken from packages/wb_dma/bench (sw_dma*, arb_test*,
// hw_dma*): fill source memory, program channel registers, run, check the
// destination against the source and the per-channel done interrupts.
//
// One class per .svh, included below in dependency order.
// ======================================================================
`include "wb_dma_spl_macros.svh"   // FW_MEM_IMP / FW_WB_DMA_IRQ_IMP / FW_WB_DMA_HS_IMP

package wb_dma_model_pkg;
    import fw_hdl_pkg::*;
    import fw_std_pkg::*;
    import wb_dma_spl_pkg::*;

    // The model's 32-bit Wishbone edge -- the abstract BFM type used both as the
    // engine register slave and as the data-memory access API. Matches the RTL's
    // boundary, so the UVM env drives all three DUT flavours through one seam.
    typedef wb_proto_if #(32, 32) wb_dma_mem_if_t;

    `include "wb_dma_mem.svh"
    `include "wb_dma_irq_collector.svh"
    `include "wb_dma_hs_device.svh"
    `include "wb_dma_model_base.svh"
    `include "wb_dma_tlm_model.svh"
endpackage
