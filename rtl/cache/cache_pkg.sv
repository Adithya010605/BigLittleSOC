// ============================================================================
// cache_pkg.sv
//
// Shared types and constants for the coherent memory system: the L1 data
// caches (l1_dcache.sv), the snooping bus (rtl/coherence/snoop_bus.sv) and
// everything that talks to them.
//
// One line size everywhere (32 bytes, the plan's figure for every cache), and
// the bus moves a whole line in one beat, so there is no burst sequencing
// anywhere in the protocol.
// ============================================================================

package cache_pkg;

  // --------------------------------------------------------------------
  // Line geometry
  // --------------------------------------------------------------------
  localparam int unsigned LINE_BYTES = 32;
  localparam int unsigned LINE_BITS  = 8 * LINE_BYTES;
  localparam int unsigned OFFSET_W   = $clog2(LINE_BYTES);    // 5
  localparam int unsigned LINE_WORDS = LINE_BYTES / 4;        // 8
  localparam int unsigned WORD_SEL_W = $clog2(LINE_WORDS);    // 3

  // --------------------------------------------------------------------
  // MSI line state
  //
  //   I  no copy
  //   S  clean copy, other caches may hold S copies too
  //   M  the only copy, possibly newer than memory
  //
  // A write-through cache never holds M: its stores go to memory at once.
  // --------------------------------------------------------------------
  typedef enum logic [1:0] {
    MSI_I = 2'd0,
    MSI_S = 2'd1,
    MSI_M = 2'd2
  } msi_e;

  // --------------------------------------------------------------------
  // Bus commands, issued by an L1 to the snooping bus.
  //
  //                 snooped as   data to requester   memory
  //   BUS_RD        SNP_RD       line                read, or written with the
  //                                                  M owner's flush
  //   BUS_RDX       SNP_INV      line                read, unless an M owner
  //                                                  forwards its line
  //   BUS_UPGR      SNP_INV      none (S -> M)       untouched
  //   BUS_WR        SNP_INV      none                word written (merged onto
  //                                                  an M owner's flush)
  //   BUS_WB        not snooped  none                victim line written
  //   BUS_UNC_RD    not snooped  word                uncached word read
  //   BUS_UNC_WR    not snooped  none                uncached word write
  //
  // BUS_WR is the write-through cache's store. BUS_WB needs no snoop because
  // the line is held in M, so no other cache can hold any copy of it.
  // --------------------------------------------------------------------
  typedef enum logic [2:0] {
    BUS_RD     = 3'd0,
    BUS_RDX    = 3'd1,
    BUS_UPGR   = 3'd2,
    BUS_WR     = 3'd3,
    BUS_WB     = 3'd4,
    BUS_UNC_RD = 3'd5,
    BUS_UNC_WR = 3'd6
  } bus_cmd_e;

  // What a snooped cache must do with its copy of the line.
  //   SNP_RD   another cache wants to read: M -> S (flushing the line)
  //   SNP_INV  another cache wants to write: S -> I, M -> I (flushing)
  typedef enum logic {
    SNP_RD  = 1'b0,
    SNP_INV = 1'b1
  } snoop_e;

  // --------------------------------------------------------------------
  // Per-cache event pulses, one bit each per cycle. Counted by the
  // testbench (and, later, by the cores' performance counters).
  // --------------------------------------------------------------------
  localparam int unsigned EV_LD_HIT    = 0;  // load served from the cache
  localparam int unsigned EV_LD_MISS   = 1;  // load needed the bus
  localparam int unsigned EV_ST_HIT    = 2;  // store done in the cache (M hit)
  localparam int unsigned EV_ST_MISS   = 3;  // store needed the bus (miss,
                                             // upgrade, or write-through)
  localparam int unsigned EV_WRITEBACK = 4;  // dirty victim written back
  localparam int unsigned EV_SNP_INV   = 5;  // a snoop invalidated a copy
  localparam int unsigned EV_SNP_FLUSH = 6;  // a snoop took a modified line
  localparam int unsigned EV_UNCACHED  = 7;  // uncached (MMIO) access
  localparam int unsigned NUM_EV       = 8;

  // L2 event pulses (snoop_bus.sv)
  localparam int unsigned L2EV_HIT       = 0;  // coherent request hit in the L2
  localparam int unsigned L2EV_MISS      = 1;  // ...missed: line fetched from memory
  localparam int unsigned L2EV_WRITEBACK = 2;  // dirty L2 victim written to memory
  localparam int unsigned L2EV_BACKINV   = 3;  // L2 victim's L1 copies invalidated
  localparam int unsigned NUM_L2EV       = 4;

  // --------------------------------------------------------------------
  // Line helpers
  // --------------------------------------------------------------------

  // Byte-enable merge of a new line over an old one.
  function automatic logic [LINE_BITS-1:0] line_merge(
      input logic [LINE_BITS-1:0]  old_line,
      input logic [LINE_BITS-1:0]  new_line,
      input logic [LINE_BYTES-1:0] be);
    logic [LINE_BITS-1:0] r;
    for (int b = 0; b < int'(LINE_BYTES); b++) begin
      r[8*b +: 8] = be[b] ? new_line[8*b +: 8] : old_line[8*b +: 8];
    end
    return r;
  endfunction

  // A word replicated into every word slot of a line, so that it sits in the
  // right lane whatever its offset; the byte enables pick the slot.
  function automatic logic [LINE_BITS-1:0] word_to_line(input logic [31:0] w);
    return {LINE_WORDS{w}};
  endfunction

  // A word's 4-bit byte enable moved to its slot in a line.
  function automatic logic [LINE_BYTES-1:0] word_be(
      input logic [3:0]            be,
      input logic [WORD_SEL_W-1:0] slot);
    return LINE_BYTES'(be) << (4 * int'(slot));
  endfunction

  // Tree pseudo-LRU over 4 ways, 3 bits per set. Bit 0 chooses the half to
  // replace next (0: ways 0-1, 1: ways 2-3); bit 1 chooses within ways 0-1,
  // bit 2 within ways 2-3. Touching a way points every bit on its path away
  // from it.
  function automatic logic [1:0] plru4_victim(input logic [2:0] b);
    return b[0] ? {1'b1, b[2]} : {1'b0, b[1]};
  endfunction

  function automatic logic [2:0] plru4_touch(input logic [2:0] b, input logic [1:0] way);
    logic [2:0] r;
    r = b;
    r[0] = ~way[1];
    if (way[1]) r[2] = ~way[0];
    else        r[1] = ~way[0];
    return r;
  endfunction

  function automatic logic [31:0] line_word(
      input logic [LINE_BITS-1:0]  line,
      input logic [WORD_SEL_W-1:0] slot);
    return line[32*int'(slot) +: 32];
  endfunction

endpackage
