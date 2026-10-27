package cn.xingzhewujiang.mineradio.tests;

import android.app.*;
import android.content.*;
import android.os.*;
import android.webkit.WebView;
import java.lang.reflect.Field;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicReference;

// Optional USB device test: actual native HTTPS, actual local HTTP audio and
// Android WebView playback. No mocked network or user account credentials.
public final class PlaybackInstrumentation extends Instrumentation {
    private WebView web;
    private final CountDownLatch created = new CountDownLatch(1);
    @Override public void onCreate(Bundle arguments) {
        super.onCreate(arguments);
        // Always bound a hardware probe, including lifecycle/main-thread stalls.
        Thread watchdog = new Thread(() -> { SystemClock.sleep(210000); Bundle b = new Bundle(); b.putString("stream", "FAIL: device probe exceeded 210 seconds\n"); finish(Activity.RESULT_CANCELED, b); }, "playback-probe-timeout");
        watchdog.setDaemon(true); watchdog.start();
        start();
    }
    @Override public void callActivityOnCreate(Activity activity, Bundle state) {
        super.callActivityOnCreate(activity, state);
        try {
            Field field = activity.getClass().getDeclaredField("web"); field.setAccessible(true); web = (WebView)field.get(activity);
            created.countDown();
        } catch (Exception ignored) { }
    }
    private String eval(String source) throws Exception {
        CountDownLatch done = new CountDownLatch(1); AtomicReference<String> result = new AtomicReference<>();
        new Handler(Looper.getMainLooper()).post(() -> web.evaluateJavascript(source, value -> { result.set(value); done.countDown(); }));
        if (!done.await(8, TimeUnit.SECONDS)) throw new Exception("WebView evaluation timeout");
        return result.get();
    }
    private void until(String expression, int seconds) throws Exception {
        long deadline = SystemClock.elapsedRealtime() + seconds * 1000L;
        while (SystemClock.elapsedRealtime() < deadline) {
            if ("true".equals(eval("Boolean(" + expression + ")"))) return;
            String error = eval("window.__phoneTestError || ''");
            if (!"\"\"".equals(error) && !"null".equals(error)) throw new Exception(error);
            SystemClock.sleep(250);
        }
        throw new Exception("Timeout: " + expression + "; " + eval("({paused:window.audio?.paused,ready:window.audio?.readyState,error:window.audio?.error?.code,title:document.querySelector('#control-title')?.textContent})"));
    }
    @Override public void onStart() {
        Bundle report = new Bundle();
        try {
            Bundle progress = new Bundle(); progress.putString("stream", "Starting real device playback probe\n"); sendStatus(1, progress);
            Intent intent = new Intent().setClassName("cn.xingzhewujiang.mineradio", "cn.xingzhewujiang.mineradio.MainActivity").addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            // startActivitySync waits for an idle UI queue; the original player's
            // continuous visual animation can prevent that idle indefinitely.
            getTargetContext().startActivity(intent);
            if (!created.await(20, TimeUnit.SECONDS)) throw new Exception("Activity creation timeout");
            until("window.splashReadyToEnter && typeof playSearchResult === 'function'", 45);
            eval("document.querySelector('#splash').click()");
            until("!document.body.classList.contains('splash-active')", 15);
            // Probe official QR issuance and waiting status, without logging in.
            eval("(async()=>{try{const q=await mineradioNative.request('music-login-key');const c=await mineradioNative.request('music-login-check',{key:q.key});window.__phoneQrCode=c.code;}catch(e){window.__phoneTestError=e.message;}})()");
            until("window.__phoneQrCode===801", 50);
            report.putString("qr", "Official key + polling: 801 (waiting), not an authenticated account test");
            eval("document.querySelector('#search-input').value='https://music.163.com/song?id=1451396976';document.querySelector('#search-input').dispatchEvent(new Event('input',{bubbles:true}))");
            until("document.querySelector('#search-results .search-result')", 60);
            eval("Promise.resolve(playSearchResult(0)).catch(e=>window.__phoneTestError=e.message)");
            until("window.audio && !audio.paused && audio.currentTime>2 && audio.readyState>=2", 150);
            String state = eval("({time:audio.currentTime,duration:audio.duration,paused:audio.paused,ready:audio.readyState,local:audio.currentSrc.startsWith(location.origin),title:document.querySelector('#control-title')?.textContent})");
            report.putString("playback", state);
            eval("window.__phoneTime=audio.currentTime");
            until("audio.currentTime>window.__phoneTime+1.5", 12);
            eval("audio.pause();playing=false;setPlayIcon(false)");
            report.putString("stream", "PASS: real Android native search/download and WebView playback advanced. " + state + "\n");
            finish(Activity.RESULT_OK, report);
        } catch (Exception e) {
            report.putString("stream", "FAIL: " + e.toString() + "\n"); finish(Activity.RESULT_CANCELED, report);
        }
    }
}
