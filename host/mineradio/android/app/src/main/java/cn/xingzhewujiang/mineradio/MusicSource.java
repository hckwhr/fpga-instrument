package cn.xingzhewujiang.mineradio;

import java.io.*;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.util.*;
import java.util.regex.*;
import org.json.*;
import android.webkit.CookieManager;
import javax.crypto.Cipher;
import javax.crypto.spec.IvParameterSpec;
import javax.crypto.spec.SecretKeySpec;
import java.security.*;
import java.security.spec.X509EncodedKeySpec;

// Android port of Mineradio's NetEase source boundary. Only actual playable
// URLs returned by the provider are used; encrypted files/absent URLs fail.
final class MusicSource {
    private static final int MAX_AUDIO = 80 * 1024 * 1024;
    private static volatile String loginKey;
    private static final String ORIGIN = "https://music.163.com";
    private static String sessionCookie() {
        String value = CookieManager.getInstance().getCookie(ORIGIN);
        return value == null ? "" : value;
    }
    // Same weapi request encoding as the existing desktop NeteaseCloudMusicApi
    // dependency. Session cookies stay in Android's private CookieManager.
    private static String aes(String text, String key) throws Exception {
        Cipher cipher = Cipher.getInstance("AES/CBC/PKCS5Padding");
        cipher.init(Cipher.ENCRYPT_MODE, new SecretKeySpec(key.getBytes(StandardCharsets.UTF_8), "AES"), new IvParameterSpec("0102030405060708".getBytes(StandardCharsets.UTF_8)));
        return Base64.getEncoder().encodeToString(cipher.doFinal(text.getBytes(StandardCharsets.UTF_8)));
    }
    static String encodeRequest(JSONObject data) throws Exception {
        String alphabet = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
        SecureRandom random = new SecureRandom(); StringBuilder secret = new StringBuilder();
        for (int i = 0; i < 16; i++) secret.append(alphabet.charAt(random.nextInt(alphabet.length())));
        String publicKey = "MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDgtQn2JZ34ZC28NWYpAUd98iZ37BUrX/aKzmFbt7clFSs6sXqHauqKWqdtLkF2KexO40H1YTX8z2lSgBBOAxLsvaklV8k4cBFK9snQXE9/DDaFt6Rr7iVZMldczhC0JNgTz+SHXT6CBHuX3e9SdB1Ua44oncaTWz7OBGLbCiK45wIDAQAB";
        Cipher rsa = Cipher.getInstance("RSA/ECB/NoPadding");
        rsa.init(Cipher.ENCRYPT_MODE, KeyFactory.getInstance("RSA").generatePublic(new X509EncodedKeySpec(Base64.getDecoder().decode(publicKey))));
        byte[] encrypted = rsa.doFinal(new StringBuilder(secret).reverse().toString().getBytes(StandardCharsets.UTF_8));
        StringBuilder hex = new StringBuilder(); for (byte b : encrypted) hex.append(String.format(Locale.ROOT, "%02x", b & 255));
        return "params=" + URLEncoder.encode(aes(aes(data.toString(), "0CoJUm6Qyw8W8jud"), secret.toString()), "UTF-8") + "&encSecKey=" + hex;
    }
    private static JSONObject api(String path, JSONObject data) throws Exception {
        String cookie = sessionCookie();
        Matcher csrf = Pattern.compile("(?:^|;\\s*)__csrf=([^;]*)").matcher(cookie);
        data.put("csrf_token", csrf.find() ? csrf.group(1) : "");
        HttpURLConnection c = open(ORIGIN + "/weapi/" + path);
        c.setRequestMethod("POST"); c.setDoOutput(true);
        c.setRequestProperty("Content-Type", "application/x-www-form-urlencoded");
        c.setRequestProperty("Cookie", "os=pc; appver=3.0.18; " + cookie);
        byte[] request = encodeRequest(data).getBytes(StandardCharsets.UTF_8);
        c.setFixedLengthStreamingMode(request.length);
        try {
            try (OutputStream output = c.getOutputStream()) { output.write(request); }
            if (c.getResponseCode() != 200) throw new IOException("网易云请求失败：HTTP " + c.getResponseCode());
            JSONObject result;
            try (InputStream input = c.getInputStream(); ByteArrayOutputStream output = new ByteArrayOutputStream()) {
                copy(input, output, 2 * 1024 * 1024); result = new JSONObject(output.toString("UTF-8"));
            }
            int code = result.optInt("code", 200);
            if (path.equals("login/qrcode/client/login")) {
                if (!data.optString("key").equals(loginKey)) throw new IOException("登录二维码已更新，请使用最新二维码");
                if (code == 803) {
                    for (Map.Entry<String,List<String>> header : c.getHeaderFields().entrySet()) {
                        if ("Set-Cookie".equalsIgnoreCase(header.getKey())) for (String value : header.getValue()) CookieManager.getInstance().setCookie(ORIGIN, value);
                    }
                    CookieManager.getInstance().flush();
                }
            } else if (code != 200) throw new IOException("网易云请求未成功：" + result.optString("message", result.optString("msg", String.valueOf(code))));
            return result;
        } finally { c.disconnect(); }
    }
    static JSONObject loginKey() throws Exception {
        JSONObject result = api("login/qrcode/unikey", BleCentral.object("type", 3));
        String key = result.optString("unikey");
        if (!key.matches("[A-Za-z0-9_-]{10,256}")) throw new IOException("网易云未返回有效登录二维码");
        loginKey = key; return BleCentral.object("key", key, "url", ORIGIN + "/login?codekey=" + key);
    }
    static JSONObject loginCheck(String key) throws Exception {
        if (loginKey == null || !loginKey.equals(key)) throw new IOException("请重新生成登录二维码");
        JSONObject result = api("login/qrcode/client/login", BleCentral.object("key", key, "type", 3));
        int code = result.optInt("code");
        JSONObject status = code == 803 ? status() : new JSONObject();
        status.put("code", code); status.put("message", result.optString("message")); return status;
    }
    static JSONObject status() throws Exception {
        if (!Pattern.compile("(?:^|;\\s*)MUSIC_U=[^;]+").matcher(sessionCookie()).find()) return BleCentral.object("loggedIn", false);
        JSONObject result = api("w/nuser/account/get", new JSONObject());
        JSONObject profile = result.optJSONObject("profile");
        if (profile == null) return BleCentral.object("loggedIn", false);
        return BleCentral.object("loggedIn", true, "provider", "netease", "nickname", profile.optString("nickname"), "userId", profile.optLong("userId"), "avatar", profile.optString("avatarUrl"), "vipType", profile.optInt("vipType"));
    }
    static JSONObject logout() {
        loginKey = null;
        for (String name : new String[]{"MUSIC_U", "__csrf"}) {
            CookieManager.getInstance().setCookie(ORIGIN, name + "=; Max-Age=0; Path=/; Domain=.music.163.com");
            CookieManager.getInstance().setCookie(ORIGIN, name + "=; Max-Age=0; Path=/");
        }
        CookieManager.getInstance().flush(); return BleCentral.object("loggedIn", false);
    }
    private static JSONObject song(JSONObject s) throws Exception {
        JSONArray artists = s.optJSONArray("artists"); if (artists == null) artists = s.optJSONArray("ar");
        List<String> names = new ArrayList<>();
        if (artists != null) for (int i = 0; i < artists.length(); i++) names.add(artists.getJSONObject(i).optString("name"));
        JSONObject album = s.optJSONObject("al"); if (album == null) album = s.optJSONObject("album");
        return BleCentral.object("id", s.getLong("id"), "name", s.optString("name"), "artist", String.join(" / ", names), "duration", s.optLong("dt", s.optLong("duration")), "cover", album == null ? "" : album.optString("picUrl"), "album", album == null ? "" : album.optString("name"), "source", "netease", "provider", "netease");
    }
    private static JSONObject playlist(JSONObject p) {
        JSONObject creator = p.optJSONObject("creator");
        return BleCentral.object("id", p.optLong("id"), "name", p.optString("name"), "cover", p.optString("coverImgUrl"), "trackCount", p.optInt("trackCount"), "creator", creator == null ? "" : creator.optString("nickname"), "specialType", p.optInt("specialType"), "subscribed", p.optBoolean("subscribed"));
    }
    static JSONObject playlists(int offset, int limit) throws Exception {
        JSONObject account = status();
        if (!account.optBoolean("loggedIn")) return BleCentral.object("loggedIn", false, "playlists", new JSONArray());
        offset = Math.max(0, offset); limit = Math.max(1, Math.min(100, limit));
        JSONObject result = api("user/playlist", BleCentral.object("uid", account.getLong("userId"), "offset", offset, "limit", limit, "includeVideo", false));
        JSONArray records = result.optJSONArray("playlist"), list = new JSONArray();
        if (records != null) for (int i = 0; i < records.length(); i++) list.put(playlist(records.getJSONObject(i)));
        return BleCentral.object("loggedIn", true, "playlists", list, "hasMore", result.optBoolean("more"), "nextOffset", offset + list.length(), "offset", offset);
    }
    static JSONObject tracks(String id, int offset, int limit) throws Exception {
        if (!id.matches("[0-9]{1,15}")) throw new IOException("歌单 ID 无效");
        offset = Math.max(0, offset); limit = Math.max(1, Math.min(100, limit));
        JSONObject p = api("v6/playlist/detail", BleCentral.object("id", id, "n", 0, "s", 0)).optJSONObject("playlist");
        if (p == null) throw new IOException("无法读取此歌单");
        JSONArray ids = p.optJSONArray("trackIds"), request = new JSONArray(), list = new JSONArray();
        if (ids == null) throw new IOException("网易云未返回歌单曲目列表");
        int end = Math.min(ids.length(), offset + limit);
        for (int i = offset; i < end; i++) request.put(BleCentral.object("id", ids.getJSONObject(i).getLong("id")));
        if (request.length() > 0) {
            JSONArray records = api("v3/song/detail", BleCentral.object("c", request.toString())).optJSONArray("songs");
            if (records != null) for (int i = 0; i < records.length(); i++) list.put(song(records.getJSONObject(i)));
        }
        return BleCentral.object("playlist", playlist(p), "tracks", list, "total", ids.length(), "offset", offset, "nextOffset", end, "hasMore", end < ids.length());
    }
    private static HttpURLConnection open(String address) throws IOException {
        URL url = new URL(address.replaceFirst("^http:", "https:"));
        if (!url.getProtocol().equals("https") || !(url.getHost().equals("music.163.com") || url.getHost().endsWith(".music.163.com") || url.getHost().endsWith(".music.126.net") || url.getHost().equals("163cn.tv") || url.getHost().equals("163cn.com"))) throw new IOException("音源地址不在网易云受支持范围");
        HttpURLConnection connection = (HttpURLConnection)url.openConnection();
        connection.setConnectTimeout(15000); connection.setReadTimeout(30000);
        connection.setInstanceFollowRedirects(false);
        connection.setRequestProperty("Referer", "https://music.163.com/");
        connection.setRequestProperty("User-Agent", "Mozilla/5.0 Mineradio-FPGA/1.0");
        return connection;
    }
    private static HttpURLConnection follow(String url) throws IOException {
        for (int i = 0; i < 6; i++) {
            HttpURLConnection c = open(url); int code = c.getResponseCode();
            if (code >= 300 && code < 400) { String next = c.getHeaderField("Location"); c.disconnect(); if (next == null) throw new IOException("音源跳转无效"); url = new URL(new URL(url), next).toString(); }
            else { if (code != 200) { c.disconnect(); throw new IOException("音源请求失败：HTTP " + code); } return c; }
        }
        throw new IOException("音源跳转次数过多");
    }
    private static JSONObject json(String url) throws Exception {
        HttpURLConnection c = follow(url);
        try (InputStream input = c.getInputStream(); ByteArrayOutputStream output = new ByteArrayOutputStream()) {
            copy(input, output, 2 * 1024 * 1024);
            JSONObject result = new JSONObject(output.toString("UTF-8"));
            if (result.optInt("code", 200) != 200) throw new IOException("网易云接口未接受请求：" + result.optString("message", String.valueOf(result.optInt("code"))));
            return result;
        } finally { c.disconnect(); }
    }
    static JSONObject search(String query, int offset, int limit) throws Exception {
        offset = Math.max(0, Math.min(10000, offset)); limit = Math.max(1, Math.min(50, limit));
        boolean hasMore = false;
        if (query == null || query.trim().isEmpty() || query.length() > 1000) throw new IOException("请输入曲名或网易云歌曲链接");
        Matcher shortLink = Pattern.compile("https://(?:163cn\\.tv|163cn\\.com)/[^\\s]+", Pattern.CASE_INSENSITIVE).matcher(query);
        if (shortLink.find()) {
            HttpURLConnection link = follow(shortLink.group());
            query = link.getURL().toString(); link.disconnect();
        }
        Matcher id = Pattern.compile("(?:[?&]id=|/song/)([0-9]+)").matcher(query);
        JSONArray records;
        if (id.find()) records = api("v3/song/detail", BleCentral.object("c", "[{\"id\":" + id.group(1) + "}]")).optJSONArray("songs");
        else {
            JSONObject response = api("search/get", BleCentral.object("s", query.trim(), "type", 1, "limit", limit, "offset", offset));
            if (response.has("result") && !(response.opt("result") instanceof JSONObject)) throw new IOException("网易云搜索响应格式不受支持，请稍后重试");
            JSONObject result = response.optJSONObject("result"); records = result == null ? null : result.optJSONArray("songs");
            hasMore = result != null && records != null && offset + records.length() < result.optInt("songCount");
        }
        JSONArray songs = new JSONArray();
        if (records != null) for (int i = 0; i < records.length(); i++) {
            songs.put(song(records.getJSONObject(i)));
        }
        return BleCentral.object("songs", songs, "hasMore", hasMore, "nextOffset", offset + songs.length());
    }
    static JSONObject lyric(String id) throws Exception {
        if (!id.matches("[0-9]{1,15}")) throw new IOException("曲目 ID 无效");
        JSONObject result = api("song/lyric", BleCentral.object("id", id, "lv", -1, "tv", -1, "kv", -1));
        JSONObject lrc = result.optJSONObject("lrc"), translated = result.optJSONObject("tlyric");
        return BleCentral.object("lyric", lrc == null ? "" : lrc.optString("lyric"), "tlyric", translated == null ? "" : translated.optString("lyric"));
    }
    static JSONObject download(JSONObject source, File directory, String base) throws Exception {
        String id = source.optString("id"); if (!id.matches("[0-9]{1,15}")) throw new IOException("曲目 ID 无效");
        JSONObject result = api("song/enhance/player/url", BleCentral.object("ids", "[" + id + "]", "br", 320000));
        JSONArray data = result.optJSONArray("data");
        if (data == null || data.length() == 0) throw new IOException("该曲暂无可读取音频");
        JSONObject info = data.getJSONObject(0);
        if (!info.isNull("freeTrialInfo")) throw new IOException("网易云仅授权试听片段，请登录有播放权限的账号或导入本地音频");
        String address = info.optString("url"); if (address.isEmpty() || address.equals("null")) throw new IOException("网易云未返回播放地址，请先登录并确认该账号可以播放此曲");
        HttpURLConnection c = follow(address);
        String extension = info.optString("type", "mp3").toLowerCase(Locale.ROOT);
        if (!Arrays.asList("mp3", "flac", "wav", "m4a", "ogg").contains(extension)) extension = "mp3";
        String filename = UUID.randomUUID() + "." + extension;
        File target = new File(directory, filename); boolean complete = false;
        try (InputStream input = c.getInputStream(); FileOutputStream output = new FileOutputStream(target)) {
            if (c.getContentLengthLong() > MAX_AUDIO) throw new IOException("音频超过 80 MB");
            long size = copy(input, output, MAX_AUDIO); if (size == 0) throw new IOException("音源返回空文件"); complete = true;
            return BleCentral.object("url", base + "incoming/" + filename, "name", source.optString("name", "网易云歌曲") + "." + extension, "mime", "audio/" + (extension.equals("mp3") ? "mpeg" : extension));
        } finally { c.disconnect(); if (!complete) target.delete(); }
    }
    static long copy(InputStream input, OutputStream output, long max) throws IOException {
        byte[] buffer = new byte[32768]; int count; long total = 0;
        while ((count = input.read(buffer)) != -1) { total += count; if (total > max) throw new IOException("文件超过允许大小"); output.write(buffer, 0, count); }
        return total;
    }
}
