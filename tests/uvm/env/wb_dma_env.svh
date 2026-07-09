// ---- env -----------------------------------------------------------------
// The register-access agent is the fwvip-wb initiator (m_init); its config is
// set by the SV top over the model's wb_proto_if register port (reg_if()), so
// the same agent drives the TLM class model and the signal-level DUTs alike.
//
// The env also hosts the always-on comparison harness: an ever-present passive
// reference model (ref_model, published by the top) and a comparator that
// cross-checks the DUT's master stream against the reference's. On the TLM top
// the DUT is itself a tapped wb_dma_ref_model, so both streams come from taps;
// on the signal tops the DUT stream comes from bus monitors (added P2/P3).
class wb_dma_env extends uvm_env;
    `uvm_component_utils(wb_dma_env)
    wb_dma_model_base    model;
    wb_dma_ref_model     ref_model;   // always-on passive reference (null if a top omits it)
    fwvip_wb_initiator   m_init;
    wb_dma_scoreboard    sb;
    wb_dma_comparator    cmp;

    function new(string name, uvm_component parent); super.new(name, parent); endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        void'(uvm_config_db #(wb_dma_model_base)::get(this, "", "model", model));
        void'(uvm_config_db #(wb_dma_ref_model)::get(this, "", "ref_model", ref_model));
        m_init = fwvip_wb_initiator::type_id::create("m_init", this);
        sb     = wb_dma_scoreboard::type_id::create("sb", this);
        cmp    = wb_dma_comparator::type_id::create("cmp", this);
    endfunction

    function void connect_phase(uvm_phase phase);
        wb_dma_ref_model dut_rm;
        super.connect_phase(phase);
        cmp.dut_model = model;
        cmp.ref_model = ref_model;
        // No reference published (e.g. a perf run) => nothing to cross-check.
        // Disable the comparator and leave the taps unbound (transparent).
        if (ref_model == null) begin
            cmp.m_enable = 1'b0;
            return;
        end
        // Reference master stream -> comparator (REF side).
        ref_model.bind_sink(cmp.sink_ref);
        // DUT master stream -> comparator (DUT side). On the TLM top the DUT IS a
        // tapped ref_model; on the signal tops the cast fails and the DUT stream
        // arrives via bus monitors instead (wired in the signal tops' env, P2/P3).
        if ($cast(dut_rm, model)) dut_rm.bind_sink(cmp.sink_dut);
    endfunction
endclass
