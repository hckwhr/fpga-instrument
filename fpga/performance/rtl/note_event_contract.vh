// audio_clk transaction: accept only on valid && ready && !flush.
// Hold valid and payload while stalled. Synchronous flush cancels pending
// transactions AND releases the receiver; it takes priority over acceptance.
// ID identifies a note occurrence, not a physical voice. OFF must match ID.
// Pitch class 0..11, octave 0..2, force 1..127. OFF payload except ID ignored.
// IDs wrap after 65536 starts; sources must not retain OFFs across a full wrap.
`ifndef NOTE_EVENT_CONTRACT_VH
`define NOTE_EVENT_CONTRACT_VH
`define NOTE_EVENT_ID_WIDTH 16
`define NOTE_EVENT_OFF 1'b0
`define NOTE_EVENT_ON 1'b1
`define NOTE_EVENT_NOTE_WIDTH 4
`define NOTE_EVENT_OCTAVE_WIDTH 2
`define NOTE_EVENT_FORCE_WIDTH 7
`endif
