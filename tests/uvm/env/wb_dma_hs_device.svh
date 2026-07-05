// ---- one channel's HW-handshake device (provides wb_dma_hs_if) ------------
// The engine blocks in wait_req() until the stimulus posts a chunk request;
// it acks via ack(). Models the dma_req/dma_ack sideband (bench req_i/ack_o).
class wb_dma_hs_device extends fw_component;
    `FW_WB_DMA_HS_IMP(wb_dma_hs_device, hs);
    event        ev_req, ev_ack;
    int unsigned n_pending, n_ack;
    bit          nd_q, rest_q;
    fw_event_set m_mons[$];       // monitors this HS port produces requests into

    function new(string name, fw_component parent); super.new(name, parent); endfunction
    function void build(); hs = new(this); endfunction

    // engine side: block for a chunk request, return latched qualifiers.
    virtual task hs_wait_req(output bit nd, output bit rest);
        while (n_pending == 0) @(ev_req);
        n_pending--;
        nd = nd_q; rest = rest_q;
    endtask
    // engine side: acknowledge the just-transferred chunk.
    virtual function void hs_ack();
        n_ack++; ->ev_ack;
    endfunction
    // engine side (arbiter): is a chunk request pending? (non-blocking)
    virtual function bit hs_has_req();
        return n_pending > 0;
    endfunction
    // engine side (fw_awaitable_if): produce request edges into monitor s.
    virtual function void hs_produce_to(fw_event_set s);
        m_mons.push_back(s);
    endfunction

    // stimulus side: request one chunk and block until the engine acks it.
    task request_chunk(input bit nd = 0, input bit rest = 0);
        int unsigned prev = n_ack;
        nd_q = nd; rest_q = rest;
        n_pending++; ->ev_req;
        foreach (m_mons[i]) m_mons[i].notify();   // produce: wake the engine's monitor
        while (n_ack == prev) @(ev_ack);
    endtask
endclass
