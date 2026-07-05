// ---- TLM flavour: engine + two memories + irq collector + HS devices -------
class wb_dma_tlm_model extends wb_dma_model_base;
    wb_dma dma;
    // TLM memory connectors: the engine's master ports connect to these
    // fw_export #(wb_proto_if) endpoints, whose access() redirects to the
    // registered wb_proto_if responder (here s0.m/s1.m -- a sequence implementing
    // wb_proto_if could be registered instead). Same responder the WB path reaches
    // through the target agent, only the connector differs.
    wb_proto_client_export #(32, 32) cx0, cx1;

    function new(string name, fw_component parent, int unsigned n_ch = 4);
        super.new(name, parent, n_ch);
    endfunction

    function void build();
        dma  = new("dma", this, n_ch);
        s0   = new("s0", this);
        s1   = new("s1", this);
        cx0  = new("cx0", this);
        cx1  = new("cx1", this);
        irqc = new("irqc", this);
        hsdev = new[n_ch];
        foreach (hsdev[i]) hsdev[i] = new($sformatf("hs%0d", i), this);
    endfunction

    function void connect();
        cx0.set_client(s0.m);                 // register the memory responder
        cx1.set_client(s1.m);
        dma.de.mif0.connect(cx0);             // engine -> connector -> responder
        dma.de.mif1.connect(cx1);
        dma.de.irq.connect(irqc.irq);
        foreach (hsdev[i]) dma.de.hs[i].connect(hsdev[i].hs);
        // TLM producer of the interrupt-change seam: the register file publishes
        // the aggregate {intb,inta} level directly to the model (int_changed).
        dma.rf.add_int_sink(this);
    endfunction

    virtual function wb_dma_mem_if_t rf_if(); return dma.rf.host.get_if(); endfunction
endclass
