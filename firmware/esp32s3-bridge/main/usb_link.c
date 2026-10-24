#include "usb_link.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int nibble(char c) {
    return c >= '0' && c <= '9' ? c-'0' : c >= 'A' && c <= 'F' ? c-'A'+10 : -1;
}
static void response(usb_link *u, const char *token, const char *text) {
    u->output_length = (size_t)snprintf(u->output, sizeof(u->output), "!USB1,%s,%s\n", token, text);
    u->output_offset = 0;
}
void usb_link_fault(usb_link *u, bridge_core *b, const char *reason) {
    if (!u->active) return;
    // Do not clear an already partially written envelope. The host will close
    // on its watchdog if there is no space to report the fault.
    if (!u->output_length) { char error[80]; snprintf(error, sizeof(error), "ERR,%s", reason); response(u, u->token, error); }
    u->active = false; bridge_close(b);
}
void usb_link_tick(usb_link *u, bridge_core *b, uint32_t now) {
    if (u->active && (uint32_t)(now-u->last_ms) >= USB_LINK_LEASE_MS) usb_link_fault(u,b,"EXPIRED");
}
static void command(usb_link *u, bridge_core *b, uint32_t now, bool available) {
    char *line = u->input;
    if (strncmp(line,"!USB1,",6) || strlen(line)<27 || line[22]!=',') return;
    char token[17]; memcpy(token,line+6,16); token[16]=0;
    for (unsigned i=0; i<16; ++i) if (nibble(token[i])<0) return;
    char *op=line+23;
    if (!strcmp(op,"OPEN")) {
        if (u->active && !strcmp(u->token,token)) { response(u,token,"READY"); u->last_ms=now; }
        else if (!available || u->active) response(u,token,"ERR,BUSY");
        else { memcpy(u->token,token,17); u->active=true; u->last_ms=now; u->sequence=0;
            bridge_open(b); bridge_subscribe(b); response(u,token,"READY"); }
        return;
    }
    if (!u->active || strcmp(u->token,token)) { response(u,token,"ERR,SESSION"); return; }
    if (!strcmp(op,"CLOSE")) { response(u,token,"BYE"); u->active=false; bridge_close(b); return; }
    if (!strcmp(op,"PING")) { u->last_ms=now; response(u,token,"PONG"); return; }
    if (strncmp(op,"DATA,",5)) { usb_link_fault(u,b,"FORMAT"); return; }
    char *number=op+5, *payload=strchr(number,',');
    if (!payload) { usb_link_fault(u,b,"FORMAT"); return; }
    *payload++=0;
    if (!*number || strlen(number)>10) { usb_link_fault(u,b,"SEQUENCE"); return; }
    for (char *p=number; *p; ++p) if (*p<'0'||*p>'9') { usb_link_fault(u,b,"SEQUENCE"); return; }
    unsigned long long sequence=strtoull(number,NULL,10);
    if (sequence!=u->sequence || sequence>=UINT32_MAX) { usb_link_fault(u,b,"SEQUENCE"); return; }
    size_t length=strlen(payload); uint8_t bytes[BRIDGE_LINE_BYTES];
    if (!length || length>sizeof(bytes)*2 || length%2) { usb_link_fault(u,b,"FORMAT"); return; }
    for (size_t i=0;i<length/2;++i) {
        int hi=nibble(payload[2*i]),lo=nibble(payload[2*i+1]);
        if (hi<0||lo<0) { usb_link_fault(u,b,"FORMAT"); return; }
        bytes[i]=(uint8_t)((hi<<4)|lo);
    }
    if (bridge_receive_ble(b,bytes,length/2,now)!=BRIDGE_OK) { usb_link_fault(u,b,"QUEUE"); return; }
    char ok[32]; snprintf(ok,sizeof(ok),"OK,%lu",(unsigned long)u->sequence++);
    u->last_ms=now; response(u,token,ok);
}
void usb_link_byte(usb_link *u, bridge_core *b, uint8_t byte, uint32_t now, bool available) {
    if (byte=='\n') {
        if (!u->discard) { u->input[u->input_length]=0; command(u,b,now,available); }
        u->input_length=0; u->discard=false;
    } else if (byte!='\r' && !u->discard) {
        if (byte<32 || byte>126 || u->input_length==sizeof(u->input)-1) { u->discard=true; u->input_length=0; }
        else u->input[u->input_length++]=(char)byte;
    }
}
void usb_link_reply(usb_link *u, bridge_core *b) {
    if (!u->active || u->output_length) return;
    const uint8_t *bytes; size_t n=bridge_notify_peek(b,259,&bytes);
    if (!n) return;
    char hex[BRIDGE_LINE_BYTES*2+1]; static const char digits[]="0123456789ABCDEF";
    for (size_t i=0;i<n;++i) { hex[2*i]=digits[bytes[i]>>4]; hex[2*i+1]=digits[bytes[i]&15]; }
    hex[2*n]=0;
    char text[BRIDGE_LINE_BYTES*2+4]; snprintf(text,sizeof(text),"RX,%s",hex);
    response(u,u->token,text); bridge_notify_sent(b,n);
}
void usb_link_written(usb_link *u,size_t count) {
    if (count>u->output_length-u->output_offset) return;
    u->output_offset+=count;
    if (u->output_offset==u->output_length) u->output_length=u->output_offset=0;
}
