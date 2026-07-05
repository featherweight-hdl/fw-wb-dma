// ---- env -----------------------------------------------------------------
// The register-access agent is the fwvip-wb initiator (m_init); its config is
// set by the SV top over the model's wb_proto_if register port (reg_if()), so
// the same agent drives the TLM class model and the signal-level DUTs alike.
class wb_dma_env extends uvm_env;
    `uvm_component_utils(wb_dma_env)
    wb_dma_model_base    model;
    fwvip_wb_initiator   m_init;
    wb_dma_scoreboard    sb;

    function new(string name, uvm_component parent); super.new(name, parent); endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        void'(uvm_config_db #(wb_dma_model_base)::get(this, "", "model", model));
        m_init = fwvip_wb_initiator::type_id::create("m_init", this);
        sb     = wb_dma_scoreboard::type_id::create("sb", this);
    endfunction
endclass
