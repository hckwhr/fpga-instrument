@(negedge audio_clk);audio_running=0;
send_text("SONG2,0123456789ABCDEF,17,STATUS,17B0\n");repeat(600)@(negedge sys_clk);
if(received!=checked)$fatal(1,"stopped audio produced ACK");
exchange("PING\n","PONG\n",15,5,5);
exchange("STOP\n","OK,STOP\n",15,5,5);
send_text("SONG2,0123456789ABCDEF,17,STATUS,17B0\n");repeat(600)@(negedge sys_clk);
if(received!=checked || !rx_dropped)$fatal(1,"busy duplicate not dropped");
audio_running=1;
exchange("","ACK2,0123456789ABCDEF,17,STATUS,0,0,4,8281,1,8281,36CB\n",15,5,5);
exchange("SONG2,0123456789ABCDEF,17,STATUS,17B0\n","ACK2,0123456789ABCDEF,17,STATUS,0,0,4,8281,1,8281,36CB\n",15,5,5);
// Legacy HELLO owns TX while the paused SONG2 STATUS completes.
@(negedge audio_clk);audio_running=0;
send_text("SONG2,0123456789ABCDEF,18,STATUS,CE72\n");send_text("HELLO\n");
wait(received>checked);audio_running=1;
exchange("",{"OK,HC05,1,9600,8N1,DEMO=TWINKLE+ODE\n","ACK2,0123456789ABCDEF,18,STATUS,0,0,4,8281,1,8281,7022\n"},16,5,5);
// Reverse ordering: legacy STOP still executes during a SONG2 response.
send_text("SONG2,0123456789ABCDEF,19,STATUS,89A1\n");wait(received>checked);send_text("STOP\n");
exchange("",{"ACK2,0123456789ABCDEF,19,STATUS,0,0,4,8281,1,8281,DC43\n","ERR,BUSY\n"},17,5,5);
exchange("PING\n","PONG\n",17,5,5);
