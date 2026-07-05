// ---- wb_proto_if memory with an optional per-access delay + backdoor ------
// `delay` models slave wait-states (the reference's s0.delay / s1.delay). The
// engine's master ports (de.mif0/mif1) connect here and drive access() calls.
class wb_dma_mem extends fw_component;
    logic [31:0]  mem [logic [31:0]];
    int unsigned  delay = 0;        // extra ns per access (wait-states)
    `FW_WB_PROTO_IMP(32, 32, wb_dma_mem, m);

    function new(string name, fw_component parent); super.new(name, parent); endfunction
    function void build(); m = new(this); endfunction

    virtual task m_access(input  logic [31:0] adr, input logic [31:0] dat_w,
                          input  logic [3:0]  sel, input bit          we,
                          output logic [31:0] dat_r, output bit        err);
        #((7 + delay) * 1ns);
        if (we) begin mem[adr] = dat_w; dat_r = 32'h0; end
        else          dat_r = mem.exists(adr) ? mem[adr] : 32'h0;
        err = 1'b0;
    endtask

    // Backdoor: fill `count` words from byte `base` with a deterministic
    // pattern {seed[15:0], i[15:0]} (cf. bench fill_mem). virtual so a flavour
    // whose store lives elsewhere (e.g. the RTL path's combinational SV RAM)
    // can redirect the backdoor without changing the scoreboard/test API.
    virtual function void fill(logic [31:0] base, int count, logic [15:0] seed);
        for (int i = 0; i < count; i++)
            mem[base + 4*i] = {seed, i[15:0]};
    endfunction
    virtual function logic [31:0] peek(logic [31:0] addr);
        return mem.exists(addr) ? mem[addr] : 32'hxxxx_xxxx;
    endfunction
endclass
