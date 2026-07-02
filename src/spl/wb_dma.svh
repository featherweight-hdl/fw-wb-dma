// Top behavioral component of the DMA model. A PURE component: it instances the
// register file and the data-mover engine and owns their structure, but knows
// nothing about signal-level transactors or pins -- the module wrapper
// (wb_dma_spl) and the testbench bind the engine's fw_mem_if / handshake / irq
// endpoints to the Wishbone world. Binding endpoints:
//   rf.host  -- host (CPU) register access (fw_mem_if slave)
//   de.mif0  -- WISHBONE IF0 master (fw_mem_if)
//   de.mif1  -- WISHBONE IF1 master (fw_mem_if)
//   de.hs[i] -- channel i HW handshake
//   de.irq   -- interrupt-cause sink
class wb_dma extends fw_component;
    int unsigned n_ch;
    wb_dma_rf    rf;
    wb_dma_de    de;

    function new(string name, fw_component parent, int unsigned n_ch = 4);
        super.new(name, parent);
        this.n_ch = n_ch;
    endfunction

    function void build();
        // Just create the immediate children; do_build() recurses top-down, so no
        // manual child.build() calls. de.build() reads rf.ch/rf.n_ch (populated in
        // the rf constructor, before any build()), so ordering is safe.
        rf = new("rf", this, n_ch);
        de = new("de", this, rf);
    endfunction
endclass
