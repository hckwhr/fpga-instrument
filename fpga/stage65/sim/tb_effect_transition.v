`timescale 1ns/1ps
// Reference runs the outgoing effect without changing its parameters.
// A true fade must follow this signal * gain, rather than a held DC sample.
module tb_effect_transition;
    reg clk=0,reset_n=0,strobe=0,mute=0;
    reg reference_reset=0,reference_setup=0;
    reg [1:0] mode=0,strength=1,reference_mode=0,reference_strength=1;
    reg signed [15:0] pcm=0;
    wire signed [15:0] actual,reference_pcm;
    integer i,m,s,kind,offset,index=0,expected,gain,checks=0,commits=0,fd;
    real angle;
`ifdef LEGACY_EFFECT_DUT
    stage22_audio_effects dut(
`else
    audio_effects dut(
`endif
        .clk(clk),.reset_n(reset_n),.sample_strobe(strobe),.mute(mute),
        .effect_select(mode),.effect_strength(strength),.sample_in(pcm),.sample_out(actual));
    stage22_audio_effects reference(.clk(clk),.reset_n(reset_n && !reference_reset),
        .sample_strobe(strobe || reference_setup),
        .mute(mute || reference_setup),.effect_select(reference_mode),.effect_strength(reference_strength),
        .sample_in(pcm),.sample_out(reference_pcm));
    always #5 clk=~clk;
    task tick;begin @(posedge clk);#1;@(negedge clk);end endtask
    task slot;begin
        // Non-integral period plus a harmonic exposes held samples at all phases.
        angle=6.283185307179586*997.0*index/48000.0;
        pcm=$rtoi(14000.0*$sin(angle)+2000.0*$sin(3.0*angle));
        index=index+1;strobe=1;tick();strobe=0;repeat(12)tick();
        if((^actual)===1'bx || actual>16000 || actual< -16000)
            $fatal(1,"unknown/clipped transition output");
    end endtask
    task scaled_check;input integer target_gain;begin
        expected=($signed(reference_pcm)*target_gain)>>>7;
        if(actual!==expected || dut.level!==target_gain)
            $fatal(1,"fade froze/changed outgoing waveform: mode=%0d strength=%0d gain=%0d got=%0d expected=%0d",
                   reference_mode,reference_strength,target_gain,actual,expected);
        checks=checks+1;
    end endtask
    task start_case;begin
        reset_n=0;repeat(4)tick();reset_n=1;
        mode=m;reference_mode=m;strength=s;reference_strength=s;mute=0;
        repeat(8500+offset)slot();
        if(actual!==reference_pcm || dut.level!=128)$fatal(1,"steady path changed");
    end endtask
    initial begin
        fd=$fopen("sim/effect_transition.csv","w");
        if(!fd)$fatal(1,"capture unavailable");
        $fwrite(fd,"mode,strength,kind,phase,sample,gain,reference,actual\n");
        for(m=0;m<4;m=m+1)for(s=0;s<3;s=s+1)
            for(kind=0;kind<2;kind=kind+1)for(offset=0;offset<4;offset=offset+1)begin
                start_case();
                if(kind==0)mode=(m+1)%4;else strength=(s+1)%3;
                for(i=0;i<128;i=i+1)begin
                    slot();scaled_check(127-i);
                    $fwrite(fd,"%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d\n",
                        m,s,kind,offset,i,127-i,reference_pcm,actual);
                    if(dut.active_mode!==reference_mode || dut.active_strength!==reference_strength)
                        $fatal(1,"effect committed before zero gain");
                end
                slot();
                if(actual!=0 || dut.level!=0 || dut.active_mode!==mode || dut.active_strength!==strength ||
                   dut.filled!=0 || dut.pointer!=0)$fatal(1,"zero-gain commit/reset failed");
                commits=commits+1;
                // The newly selected effect must agree with a clean instance.
                reference_reset=1;repeat(3)tick();
                reference_mode=mode;reference_strength=strength;reference_reset=0;
                reference_setup=1;tick();reference_setup=0;repeat(12)tick();
                repeat(400)slot();
                repeat(64)begin slot();if(actual!==reference_pcm)$fatal(1,"post-switch history mismatch");end
            end
        // Reversing the request partway through fade must preserve old history.
        for(m=0;m<4;m=m+1)begin
            s=1;offset=0;start_case();mode=(m+1)%4;
            for(i=0;i<40;i=i+1)begin slot();scaled_check(127-i);end
            mode=m;
            for(i=0;i<40;i=i+1)begin slot();scaled_check(89+i);end
            slot();scaled_check(128);
            // Mute still reaches zero and restart never exposes stale RAM.
            mute=1;repeat(140)slot();
            if(actual!=0 || dut.level!=0)$fatal(1,"mute failed");
            pcm=0;mute=0;
            for(i=0;i<2000;i=i+1)begin
                strobe=1;tick();strobe=0;repeat(12)tick();
                if(actual!=0)$fatal(1,"stale tail after mute");
            end
        end
        $fclose(fd);
        $display("PASS: %0d mode/strength/phase transitions, %0d exact outgoing-waveform fade checks; cancel, mute, restart",
                 commits,checks);
        $finish;
    end
    initial begin #2000000000;$fatal(1,"transition timeout");end
endmodule
