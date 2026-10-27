package cn.xingzhewujiang.mineradio;

import android.Manifest;
import android.app.*;
import android.content.*;
import android.content.pm.PackageManager;
import android.database.Cursor;
import android.net.Uri;
import android.os.*;
import android.provider.OpenableColumns;
import android.util.Base64;
import android.view.WindowManager;
import android.webkit.*;
import java.io.*;
import java.util.*;
import java.util.concurrent.*;
import org.json.*;

@SuppressWarnings("deprecation")
public final class MainActivity extends Activity {
    private WebView web;
    private AssetServer server;
    private BleCentral ble;
    private File incoming;
    private final ExecutorService workers = Executors.newFixedThreadPool(2);
    private ValueCallback<Uri[]> chooser;
    private String permissionId, saveId;
    private JSONObject permissionConfig, shared;
    private byte[] saveBytes;
    private boolean pageReady;
    private volatile boolean destroyed;
    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        incoming = new File(getCacheDir(), "incoming"); incoming.mkdirs();
        // Cached imports are temporary; only remove previous-session files.
        File[] old = incoming.listFiles(); if (old != null) for (File f : old) if (f.isFile()) f.delete();
        try { server = new AssetServer(this, incoming); }
        catch (IOException e) { new AlertDialog.Builder(this).setMessage("本地资源服务启动失败：" + e.getMessage()).setPositiveButton("关闭", (d, w) -> finish()).show(); return; }
        ble = new BleCentral(this); web = new WebView(this);
        WebSettings settings = web.getSettings(); settings.setJavaScriptEnabled(true); settings.setDomStorageEnabled(true);
        settings.setAllowFileAccess(false); settings.setAllowContentAccess(true);
        settings.setMixedContentMode(WebSettings.MIXED_CONTENT_NEVER_ALLOW);
        // The explicit player action waits for native HTTPS download first.
        // Its user activation has expired by the time media.play() runs.
        // Only our local app UI is loaded in this WebView.
        settings.setMediaPlaybackRequiresUserGesture(false);
        web.addJavascriptInterface(new Bridge(), "NativeApp");
        web.setWebViewClient(new WebViewClient() {
            @Override public boolean shouldOverrideUrlLoading(WebView view, WebResourceRequest request) {
                String url = request.getUrl().toString();
                // Never expose the native bridge to a remote page. External links
                // open in the browser without this interface.
                if (url.startsWith(server.base())) return false;
                if (request.isForMainFrame() && (url.startsWith("https://") || url.startsWith("http://"))) {
                    try { startActivity(new Intent(Intent.ACTION_VIEW, request.getUrl())); } catch (ActivityNotFoundException ignored) {}
                }
                return true;
            }
        });
        web.setWebChromeClient(new WebChromeClient() {
            @Override public boolean onShowFileChooser(WebView view, ValueCallback<Uri[]> callback, FileChooserParams params) {
                if (chooser != null) chooser.onReceiveValue(null); chooser = callback;
                Intent intent = new Intent(Intent.ACTION_OPEN_DOCUMENT); intent.addCategory(Intent.CATEGORY_OPENABLE);
                intent.setType("*/*");
                intent.putExtra(Intent.EXTRA_ALLOW_MULTIPLE, params.getMode() == FileChooserParams.MODE_OPEN_MULTIPLE);
                // Android's picker interprets MIME types, not browser .mid/.json
                // extension accept tokens. Let the established JS parsers validate.
                try { startActivityForResult(intent, 21); } catch (ActivityNotFoundException e) { chooser.onReceiveValue(null); chooser = null; }
                return true;
            }
        });
        setContentView(web); web.loadUrl(server.base() + "android.html"); handleIntent(getIntent());
    }
    private final class Bridge {
        @JavascriptInterface public void request(String id, String operation, String payload) {
            if (destroyed || id == null || id.length() > 40 || payload == null || payload.length() > 4 * 1024 * 1024) return;
            try {
                JSONObject body = new JSONObject(payload);
                runOnUiThread(() -> {
                    if (destroyed) return;
                    try {
                        switch (operation) {
                        case "ready": pageReady = true; success(id, shared == null ? new JSONObject() : shared); shared = null; break;
                        case "ble-connect": requestBle(id, body); break;
                        case "ble-write": ble.write(id, Base64.decode(body.getString("data"), Base64.DEFAULT)); break;
                        case "ble-disconnect": ble.close(); success(id, new JSONObject()); break;
                        case "music-search": work(id, () -> MusicSource.search(body.optString("query"), body.optInt("offset"), body.optInt("limit", 20))); break;
                        case "music-lyric": work(id, () -> MusicSource.lyric(body.optString("id"))); break;
                        case "music-download": work(id, () -> MusicSource.download(body, incoming, server.base())); break;
                        case "music-login-key": work(id, MusicSource::loginKey); break;
                        case "music-login-check": work(id, () -> MusicSource.loginCheck(body.optString("key"))); break;
                        case "music-status": work(id, MusicSource::status); break;
                        case "music-playlists": work(id, () -> MusicSource.playlists(body.optInt("offset"), body.optInt("limit", 48))); break;
                        case "music-playlist-tracks": work(id, () -> MusicSource.tracks(body.optString("id"), body.optInt("offset"), body.optInt("limit", 48))); break;
                        case "music-logout": work(id, MusicSource::logout); break;
                        case "save-login-qr": work(id, () -> saveLoginQr(body.getString("data"))); break;
                        case "keep-awake":
                            if (body.optBoolean("enabled")) getWindow().addFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
                            else getWindow().clearFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
                            success(id, new JSONObject()); break;
                        case "save-file":
                            if (saveId != null) throw new IllegalStateException("请先完成上一次保存");
                            saveBytes = Base64.decode(body.getString("data"), Base64.DEFAULT);
                            if (saveBytes.length > 2 * 1024 * 1024) throw new IllegalArgumentException("存档超过 2 MB");
                            saveId = id;
                            Intent save = new Intent(Intent.ACTION_CREATE_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE).setType(body.optString("mime", "application/octet-stream")).putExtra(Intent.EXTRA_TITLE, body.optString("name", "score.json"));
                            startActivityForResult(save, 22); break;
                        default: failure(id, "不支持的原生操作");
                        }
                    } catch (Exception e) { if (id.equals(saveId)) { saveId = null; saveBytes = null; } failure(id, e.getMessage()); }
                });
            } catch (Exception e) { failure(id, e.getMessage()); }
        }
    }
    private interface Job { JSONObject run() throws Exception; }
    private JSONObject saveLoginQr(String encoded) throws Exception {
        byte[] bytes = Base64.decode(encoded, Base64.DEFAULT);
        if (bytes.length > 128 * 1024 || bytes.length < 8 || bytes[0] != (byte)137 || bytes[1] != 80 || bytes[2] != 78 || bytes[3] != 71) throw new IOException("二维码图片无效");
        if (Build.VERSION.SDK_INT < 29) throw new IOException("请截屏后使用网易云扫一扫从相册识别");
        ContentValues values = new ContentValues();
        values.put(android.provider.MediaStore.Images.Media.DISPLAY_NAME, "FPGAvedio-网易云登录-" + System.currentTimeMillis() + ".png");
        values.put(android.provider.MediaStore.Images.Media.MIME_TYPE, "image/png");
        values.put(android.provider.MediaStore.Images.Media.RELATIVE_PATH, "Pictures/FPGAvedio");
        values.put(android.provider.MediaStore.Images.Media.IS_PENDING, 1);
        Uri uri = getContentResolver().insert(android.provider.MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values);
        if (uri == null) throw new IOException("无法保存二维码到相册");
        try {
            try (OutputStream out = getContentResolver().openOutputStream(uri)) { if (out == null) throw new IOException("无法写入相册"); out.write(bytes); }
            ContentValues ready = new ContentValues(); ready.put(android.provider.MediaStore.Images.Media.IS_PENDING, 0);
            getContentResolver().update(uri, ready, null, null);
        } catch (Exception e) { getContentResolver().delete(uri, null, null); throw e; }
        return BleCentral.object("saved", true);
    }
    private void work(String id, Job job) { workers.execute(() -> { try { success(id, job.run()); } catch (Exception e) { failure(id, e.getMessage()); } }); }
    private void requestBle(String id, JSONObject config) {
        if (permissionId != null) { failure(id, "请先完成蓝牙授权"); return; }
        String[] permissions = Build.VERSION.SDK_INT >= 31 ? new String[]{Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT} : new String[]{Manifest.permission.ACCESS_FINE_LOCATION};
        for (String p : permissions) if (checkSelfPermission(p) != PackageManager.PERMISSION_GRANTED) {
            permissionId = id; permissionConfig = config; requestPermissions(permissions, 20); return;
        }
        ble.connect(id, config);
    }
    @Override public void onRequestPermissionsResult(int request, String[] permissions, int[] results) {
        super.onRequestPermissionsResult(request, permissions, results);
        if (request != 20 || permissionId == null) return;
        String id = permissionId; JSONObject config = permissionConfig; permissionId = null; permissionConfig = null;
        if (results.length == 0) { failure(id, "未授予蓝牙权限"); return; }
        for (int r : results) if (r != PackageManager.PERMISSION_GRANTED) { failure(id, "需要附近设备／蓝牙权限才能连接行者无疆"); return; }
        ble.connect(id, config);
    }
    @Override protected void onNewIntent(Intent intent) { super.onNewIntent(intent); setIntent(intent); handleIntent(intent); }
    private void handleIntent(Intent intent) {
        if (intent == null) return;
        String action = intent.getAction();
        Uri uri = Intent.ACTION_SEND.equals(action) ? intent.getParcelableExtra(Intent.EXTRA_STREAM) : Intent.ACTION_VIEW.equals(action) ? intent.getData() : null;
        if (uri != null && uri.getScheme().equals("content")) {
            workers.execute(() -> {
                File destination = null;
                try {
                    String name = "共享音频.mp3";
                    try (Cursor cursor = getContentResolver().query(uri, new String[]{OpenableColumns.DISPLAY_NAME}, null, null, null)) { if (cursor != null && cursor.moveToFirst()) name = cursor.getString(0); }
                    String extension = name.contains(".") ? name.substring(name.lastIndexOf('.')).toLowerCase(Locale.ROOT) : ".mp3";
                    if (!Arrays.asList(".mp3", ".wav", ".flac", ".m4a", ".ogg", ".aac", ".opus").contains(extension)) throw new IOException("请分享普通 MP3/WAV/FLAC 音频文件，不能使用专属加密文件");
                    destination = new File(incoming, UUID.randomUUID() + extension);
                    try (InputStream input = getContentResolver().openInputStream(uri); FileOutputStream output = new FileOutputStream(destination)) {
                        if (input == null || MusicSource.copy(input, output, 80 * 1024 * 1024) == 0) throw new IOException("共享音频为空");
                    }
                    JSONObject file = BleCentral.object("url", server.base() + "incoming/" + destination.getName(), "name", name, "mime", getContentResolver().getType(uri));
                    runOnUiThread(() -> { if (pageReady) { JSONObject event = BleCentral.object("type", "shared-audio"); try { for (Iterator<String> it = file.keys(); it.hasNext();) { String key = it.next(); event.put(key, file.get(key)); } } catch (JSONException ignored) {} event(event); } else shared = BleCentral.object("file", file); });
                } catch (Exception e) { if (destination != null) destination.delete(); runOnUiThread(() -> android.widget.Toast.makeText(this, e.getMessage(), android.widget.Toast.LENGTH_LONG).show()); }
            });
        } else if (Intent.ACTION_SEND.equals(action) && intent.getStringExtra(Intent.EXTRA_TEXT) != null) {
            String text = intent.getStringExtra(Intent.EXTRA_TEXT);
            if (pageReady) event(BleCentral.object("type", "shared-text", "text", text)); else shared = BleCentral.object("text", text);
        }
    }
    @Override protected void onActivityResult(int request, int result, Intent data) {
        super.onActivityResult(request, result, data);
        if (request == 21 && chooser != null) {
            Uri[] selected = null;
            if (result == RESULT_OK && data != null) {
                if (data.getClipData() != null) {
                    ClipData files = data.getClipData(); selected = new Uri[files.getItemCount()];
                    for (int i = 0; i < selected.length; i++) selected[i] = files.getItemAt(i).getUri();
                } else if (data.getData() != null) selected = new Uri[]{data.getData()};
            }
            chooser.onReceiveValue(selected); chooser = null;
        }
        if (request == 22 && saveId != null) {
            String id = saveId; byte[] bytes = saveBytes; saveId = null; saveBytes = null;
            if (result != RESULT_OK || data == null || data.getData() == null) { failure(id, "已取消保存"); return; }
            Uri uri = data.getData();
            work(id, () -> { try (OutputStream out = getContentResolver().openOutputStream(uri)) { if (out == null) throw new IOException("无法写入所选位置"); out.write(bytes); } return new JSONObject(); });
        }
    }
    void success(String id, JSONObject result) { event(BleCentral.object("id", id, "result", result)); }
    void failure(String id, String message) { event(BleCentral.object("id", id, "error", message == null ? "操作失败" : message)); }
    void event(JSONObject message) {
        runOnUiThread(() -> { if (!destroyed && web != null) web.evaluateJavascript("window.mineradioNative && window.mineradioNative.deliver(" + message.toString() + ")", null); });
    }
    @Override public void onBackPressed() {
        if (web == null) { super.onBackPressed(); return; }
        web.evaluateJavascript("!document.body.classList.contains('fpga-playback-mode')", result -> {
            if ("true".equals(result)) super.onBackPressed();
            else web.evaluateJavascript("document.getElementById('mode-player').click()", null);
        });
    }
    @Override protected void onDestroy() {
        destroyed = true; if (ble != null) ble.close(); workers.shutdownNow();
        try { if (server != null) server.close(); } catch (IOException ignored) {}
        if (chooser != null) chooser.onReceiveValue(null);
        if (web != null) { web.removeJavascriptInterface("NativeApp"); web.destroy(); }
        super.onDestroy();
    }
}
