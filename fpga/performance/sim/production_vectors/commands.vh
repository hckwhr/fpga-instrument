// Generated with the production host encoder; sequences follow pcm_upload.vh.
task automatic play_first; begin exchange("SONG2,0123456789ABCDEF,4,PLAY,4,8281,1,320E\n","ACK2,0123456789ABCDEF,4,PLAY,1,0,4,8281,1,8281,67D3\n"); end endtask
task automatic stop_first; begin exchange("SONG2,0123456789ABCDEF,5,STOP,0F2F\n","ACK2,0123456789ABCDEF,5,STOP,0,0,4,8281,1,8281,F9D3\n"); end endtask
task automatic play_to_end; begin exchange("SONG2,0123456789ABCDEF,6,PLAY,4,8281,1,7FD7\n","ACK2,0123456789ABCDEF,6,PLAY,1,0,4,8281,1,8281,09D5\n"); end endtask
task automatic status_finished; begin exchange("SONG2,0123456789ABCDEF,7,STATUS,AF53\n","ACK2,0123456789ABCDEF,7,STATUS,3,1,4,8281,1,8281,2798\n"); end endtask
task automatic play_local_stop; begin exchange("SONG2,0123456789ABCDEF,8,PLAY,4,8281,1,8EF9\n","ACK2,0123456789ABCDEF,8,PLAY,1,0,4,8281,1,8281,13E6\n"); end endtask
task automatic status_local_stop; begin exchange("SONG2,0123456789ABCDEF,9,STATUS,3142\n","ACK2,0123456789ABCDEF,9,STATUS,0,0,4,8281,1,8281,52CA\n"); end endtask
task automatic play_in_menu; begin exchange("SONG2,0123456789ABCDEF,10,PLAY,4,8281,1,8DBD\n","ERR2,0123456789ABCDEF,10,PLAY,BUSY,89C4\n"); end endtask
task automatic play_in_builtin; begin exchange("SONG2,0123456789ABCDEF,10,PLAY,4,8281,1,8DBD\n","ERR2,0123456789ABCDEF,10,PLAY,BUSY,89C4\n"); end endtask
