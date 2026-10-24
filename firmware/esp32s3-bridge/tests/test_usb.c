#include "usb_link.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

#define TOKEN "0123456789ABCDEF"
#define OTHER "FEDCBA9876543210"
static void feed(usb_link *u, bridge_core *b, const char *s, uint32_t now, bool available) {
    while (*s) usb_link_byte(u,b,(uint8_t)*s++,now,available);
}
static void expect(usb_link *u, const char *s) {
    assert(u->output_length==strlen(s));
    assert(memcmp(u->output,s,strlen(s))==0);
    usb_link_written(u,1); // partial USB driver writes preserve all bytes
    assert(u->output_offset==1);
    usb_link_written(u,u->output_length-1);
    assert(!u->output_length && !u->output_offset);
}
static void open_link(usb_link *u, bridge_core *b, uint32_t now) {
    feed(u,b,"!USB1," TOKEN ",OPEN\n",now,true);
    expect(u,"!USB1," TOKEN ",READY\n");
    assert(u->active && b->connected && b->subscribed);
}
int main(void) {
    usb_link u={0}; bridge_core b={0};
    feed(&u,&b,"boot log\nPING\n",0,true);
    assert(!b.connected && !u.output_length);
    feed(&u,&b,"!USB1," TOKEN ",OPEN\n",0,false);
    expect(&u,"!USB1," TOKEN ",ERR,BUSY\n");
    assert(!b.connected);
    open_link(&u,&b,UINT32_MAX-1000);
    feed(&u,&b,"!USB1," OTHER ",OPEN\n",0,true);
    expect(&u,"!USB1," OTHER ",ERR,BUSY\n");
    feed(&u,&b,"!USB1," OTHER ",DATA,0,50494E470A\n",0,true);
    expect(&u,"!USB1," OTHER ",ERR,SESSION\n");
    assert(!b.to_uart.count && u.active);
    feed(&u,&b,"!USB1," TOKEN ",DATA,0,50494E470A\n",0,false);
    expect(&u,"!USB1," TOKEN ",OK,0\n");
    const bridge_line *line=bridge_uart_front(&b);
    assert(line && line->length==5 && !memcmp(line->data,"PING\n",5));
    bridge_uart_sent(&b);
    assert(bridge_receive_uart(&b,(const uint8_t *)"ACK\n",4,1)==BRIDGE_OK);
    usb_link_reply(&u,&b);
    expect(&u,"!USB1," TOKEN ",RX,41434B0A\n");
    assert(!b.to_ble.count);
    feed(&u,&b,"!USB1," TOKEN ",DATA,0,504C41590A\n",1,false);
    expect(&u,"!USB1," TOKEN ",ERR,SEQUENCE\n");
    assert(!u.active && !b.connected && !b.to_uart.count);
    open_link(&u,&b,10);
    feed(&u,&b,"!USB1," TOKEN ",DATA,0,GG\n",10,false);
    expect(&u,"!USB1," TOKEN ",ERR,FORMAT\n");
    assert(!u.active);
    open_link(&u,&b,UINT32_MAX-1000);
    usb_link_tick(&u,&b,3998); assert(u.active);
    usb_link_tick(&u,&b,3999); assert(!u.active && !b.connected);
    expect(&u,"!USB1," TOKEN ",ERR,EXPIRED\n");
    open_link(&u,&b,10000);
    feed(&u,&b,"!USB1," TOKEN ",PING\n",10001,false);
    expect(&u,"!USB1," TOKEN ",PONG\n");
    feed(&u,&b,"!USB1," TOKEN ",DATA,0,504C41590A\n",10002,false);
    usb_link_written(&u,2);
    usb_link_fault(&u,&b,"TEST");
    assert(!u.active && !b.connected && !b.to_uart.count && u.output_offset==2);
    usb_link_written(&u,u.output_length-2);
    open_link(&u,&b,20000);
    feed(&u,&b,"!USB1," TOKEN ",CLOSE\n",20001,false);
    expect(&u,"!USB1," TOKEN ",BYE\n");
    assert(!u.active && !b.connected);
    puts("PASS USB framing, session exclusion, queue ACK vs FPGA reply, sequence, invalid hex, wraparound lease, partial writes, close/fault cleanup");
    return 0;
}
