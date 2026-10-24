package cn.xingzhewujiang.mineradio;

import java.io.*;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.util.*;
import java.util.regex.*;
import org.json.*;

// Android port of Mineradio's NetEase source boundary. Only actual playable
// URLs returned by the provider are used; encrypted files/absent URLs fail.
final class MusicSource {
    private static final int MAX_AUDIO = 80 * 1024 * 1024;
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
    static JSONObject search(String query) throws Exception {
        if (query == null || query.trim().isEmpty() || query.length() > 1000) throw new IOException("请输入曲名或网易云歌曲链接");
        Matcher shortLink = Pattern.compile("https://(?:163cn\\.tv|163cn\\.com)/[^\\s]+", Pattern.CASE_INSENSITIVE).matcher(query);
        if (shortLink.find()) {
            HttpURLConnection link = follow(shortLink.group());
            query = link.getURL().toString(); link.disconnect();
        }
        Matcher id = Pattern.compile("(?:[?&]id=|/song/)([0-9]+)").matcher(query);
        JSONArray records;
        if (id.find()) records = json("https://music.163.com/api/song/detail/?ids=" + URLEncoder.encode("[" + id.group(1) + "]", "UTF-8")).optJSONArray("songs");
        else {
            JSONObject response = json("https://music.163.com/api/search/get/web?s=" + URLEncoder.encode(query.trim(), "UTF-8") + "&type=1&limit=20&offset=0");
            JSONObject result = response.optJSONObject("result"); records = result == null ? null : result.optJSONArray("songs");
        }
        JSONArray songs = new JSONArray();
        if (records != null) for (int i = 0; i < records.length(); i++) {
            JSONObject s = records.getJSONObject(i); JSONArray artists = s.optJSONArray("artists");
            if (artists == null) artists = s.optJSONArray("ar");
            List<String> names = new ArrayList<>();
            if (artists != null) for (int a = 0; a < artists.length(); a++) names.add(artists.getJSONObject(a).optString("name"));
            songs.put(BleCentral.object("id", s.getLong("id"), "name", s.optString("name"), "artist", String.join(" / ", names)));
        }
        return BleCentral.object("songs", songs);
    }
    static JSONObject download(JSONObject source, File directory, String base) throws Exception {
        String id = source.optString("id"); if (!id.matches("[0-9]{1,15}")) throw new IOException("曲目 ID 无效");
        JSONObject result = json("https://music.163.com/api/song/enhance/player/url?ids=" + URLEncoder.encode("[" + id + "]", "UTF-8") + "&br=128000");
        JSONArray data = result.optJSONArray("data");
        if (data == null || data.length() == 0) throw new IOException("该曲暂无可读取音频");
        JSONObject info = data.getJSONObject(0);
        if (!info.isNull("freeTrialInfo")) throw new IOException("该曲仅提供试听片段，请导入有权读取的普通音频文件");
        String address = info.optString("url"); if (address.isEmpty() || address.equals("null")) throw new IOException("该曲未开放普通音频，请从音乐 App 导出文件后导入");
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
