package cn.xingzhewujiang.mineradio;

import android.content.Context;
import java.io.*;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.util.*;
import java.util.concurrent.*;

// Loopback origin makes ES modules, Workers, WASM and audio decode behave exactly
// as on desktop. Random path + same-origin navigation isolate the native bridge.
final class AssetServer implements Closeable {
    private final Context context;
    private final File incoming;
    private final ServerSocket server;
    private final ExecutorService pool = Executors.newFixedThreadPool(4);
    private final String prefix;
    private volatile boolean closed;
    AssetServer(Context context, File incoming) throws IOException {
        this.context = context; this.incoming = incoming;
        android.content.SharedPreferences preferences = context.getSharedPreferences("asset-origin", Context.MODE_PRIVATE);
        prefix = preferences.getString("prefix", "/" + UUID.randomUUID() + "/");
        ServerSocket binding;
        try { binding = new ServerSocket(preferences.getInt("port", 0), 8, InetAddress.getByName("127.0.0.1")); }
        catch (BindException occupied) { binding = new ServerSocket(0, 8, InetAddress.getByName("127.0.0.1")); }
        server = binding;
        preferences.edit().putInt("port", server.getLocalPort()).putString("prefix", prefix).apply();
        Thread accept = new Thread(() -> {
            while (!closed) try { Socket socket = server.accept(); pool.execute(() -> serve(socket)); }
            catch (IOException | RejectedExecutionException e) { if (closed) break; }
        }, "mineradio-assets"); accept.setDaemon(true); accept.start();
    }
    String base() { return "http://127.0.0.1:" + server.getLocalPort() + prefix; }
    private void serve(Socket socket) {
        try (Socket client = socket) {
            client.setSoTimeout(10000);
            BufferedReader reader = new BufferedReader(new InputStreamReader(client.getInputStream(), StandardCharsets.US_ASCII));
            String line = reader.readLine(); if (line == null) return;
            String[] request = line.split(" ");
            if (request.length < 2 || !(request[0].equals("GET") || request[0].equals("HEAD"))) return;
            String range = null;
            for (int i = 0; i < 100 && (line = reader.readLine()) != null && !line.isEmpty(); i++)
                if (line.toLowerCase(Locale.ROOT).startsWith("range:")) range = line.substring(6).trim();
            String path = URLDecoder.decode(request[1].split("\\?", 2)[0].replace("+", "%2B"), "UTF-8");
            if (!path.startsWith(prefix) || path.contains("..") || path.contains("\\")) { error(client, 403); return; }
            path = path.substring(prefix.length());
            InputStream stream;
            long length;
            try {
                if (path.startsWith("incoming/")) {
                    File file = new File(incoming, path.substring(9));
                    if (!file.getCanonicalPath().startsWith(incoming.getCanonicalPath() + File.separator)) { error(client, 403); return; }
                    length = file.length(); stream = new FileInputStream(file);
                } else {
                    stream = context.getAssets().open(path);
                    length = stream.available();
                }
            } catch (IOException e) { error(client, 404); return; }
            try (InputStream input = stream) {
                long start = 0, end = length - 1;
                boolean partial = range != null && range.matches("bytes=\\d+-\\d*");
                if (partial) {
                    String[] bounds = range.substring(6).split("-", -1); start = Long.parseLong(bounds[0]);
                    if (!bounds[1].isEmpty()) end = Math.min(end, Long.parseLong(bounds[1]));
                    if (start > end || start >= length) { error(client, 416); return; }
                }
                OutputStream out = client.getOutputStream();
                String headers = "HTTP/1.1 " + (partial ? "206 Partial Content" : "200 OK") + "\r\nContent-Type: " + mime(path) +
                    "\r\nContent-Length: " + (end - start + 1) + "\r\nConnection: close\r\nAccept-Ranges: bytes\r\nX-Content-Type-Options: nosniff\r\n" +
                    (partial ? "Content-Range: bytes " + start + "-" + end + "/" + length + "\r\n" : "") + "\r\n";
                out.write(headers.getBytes(StandardCharsets.US_ASCII));
                if (request[0].equals("HEAD")) return;
                long skipped = 0; while (skipped < start) { long n = input.skip(start - skipped); if (n <= 0) throw new EOFException(); skipped += n; }
                byte[] buffer = new byte[32768]; long remaining = end - start + 1;
                while (remaining > 0) { int n = input.read(buffer, 0, (int)Math.min(buffer.length, remaining)); if (n < 0) break; out.write(buffer, 0, n); remaining -= n; }
                out.flush();
            }
        } catch (IOException | IllegalArgumentException ignored) { /* Client navigation/seek may cancel a resource. */ }
    }
    private void error(Socket socket, int status) throws IOException {
        socket.getOutputStream().write(("HTTP/1.1 " + status + " Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n").getBytes(StandardCharsets.US_ASCII));
    }
    private String mime(String path) {
        if (path.endsWith(".html")) return "text/html; charset=utf-8";
        if (path.endsWith(".js")) return "text/javascript; charset=utf-8";
        if (path.endsWith(".css")) return "text/css; charset=utf-8";
        if (path.endsWith(".json")) return "application/json";
        if (path.endsWith(".wasm")) return "application/wasm";
        if (path.endsWith(".mp3")) return "audio/mpeg";
        if (path.endsWith(".wav")) return "audio/wav";
        if (path.endsWith(".flac")) return "audio/flac";
        if (path.endsWith(".m4a")) return "audio/mp4";
        if (path.endsWith(".ogg") || path.endsWith(".opus")) return "audio/ogg";
        if (path.endsWith(".aac")) return "audio/aac";
        return "application/octet-stream";
    }
    public void close() throws IOException { closed = true; server.close(); pool.shutdownNow(); }
}
