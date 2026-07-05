// ---- WB env: the shared UVM env + a GPIO monitor on the interrupt pins ----
// Injected into the WB top via a factory override of wb_dma_env, so the shared
// env, tests, and the TLM path are untouched.
class wb_dma_wb_env extends wb_dma_env;
    `uvm_component_utils(wb_dma_wb_env)
    fwvip_gpio_monitor  m_int;       // taps {intb_o, inta_o} (WIDTH=2)
    wb_dma_int_gpio_sub m_int_sub;

    function new(string name, uvm_component parent); super.new(name, parent); endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);    // builds agent/sb/model (model from config_db)
        m_int     = fwvip_gpio_monitor::type_id::create("m_int", this);
        m_int_sub = wb_dma_int_gpio_sub::type_id::create("m_int_sub", this);
    endfunction

    function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);
        m_int_sub.model = model;     // model handle fetched by wb_dma_env
        m_int.ap.connect(m_int_sub.analysis_export);
    endfunction
endclass
