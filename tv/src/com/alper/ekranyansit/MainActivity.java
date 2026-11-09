package com.alper.ekranyansit;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.SharedPreferences;
import android.graphics.Color;
import android.media.AudioFormat;
import android.media.AudioManager;
import android.media.AudioTrack;
import android.media.MediaCodec;
import android.media.MediaFormat;
import android.os.Build;
import android.os.Bundle;
import android.util.Log;
import android.view.Gravity;
import android.view.KeyEvent;
import android.view.Surface;
import android.graphics.SurfaceTexture;
import android.view.TextureView;
import android.view.View;
import android.view.WindowManager;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.widget.FrameLayout;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.TextView;

import java.io.BufferedInputStream;
import java.io.DataInputStream;
import java.net.Inet4Address;
import java.net.InetAddress;
import java.net.NetworkInterface;
import java.net.ServerSocket;
import java.net.Socket;
import java.nio.ByteBuffer;
import java.util.Collections;
import java.util.concurrent.LinkedBlockingQueue;
import java.util.concurrent.TimeUnit;

/**
 * Mac'ten gelen akışı oynatır. Protokol (big-endian), her paket:
 * [tip u8][pts µs u64][uzunluk u32][veri]
 * tip 0 = video config (genişlik u32, yükseklik u32, Annex-B SPS+PPS)
 * tip 1 = H.264 kare (Annex-B), tip 2 = PCM s16le stereo 48 kHz
 */
public class MainActivity extends Activity implements TextureView.SurfaceTextureListener {
    static final String TAG = "EkranYansit";
    static final int PORT = 7070;
    static final int MAX_AUDIO_CHUNKS = 10; // ~200 ms; fazlası atılır ki gecikme birikmesin

    volatile Surface surface;
    volatile ServerSocket server;
    volatile boolean audioOn, fill;
    int videoW, videoH;
    FrameLayout root;
    // TextureView: bu kutuda SurfaceView donanım katmanı arayüzün üstünde kalıyor ve imleç görünmüyor
    TextureView video;
    View waiting;
    ImageView cursor;   // Mac'ten ayrı gelen imleç: tampona girmez, anında çizilir
    float lastX = -1, lastY = -1; // son imleç konumu: görsel sonradan gelirse yerine koymak için
    float hotX, hotY, normW; // imleç sıcak noktası (görsel içinde 0…1) ve genişliği (video genişliğine oranla)
    TextView status;
    SharedPreferences prefs;
    android.net.wifi.WifiManager.WifiLock wifiLock;

    @Override
    protected void onCreate(Bundle b) {
        super.onCreate(b);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        // Wi-Fi güç tasarrufu paketleri ~100 ms'lik beacon aralıklarında toplu teslim ediyor (görüntü takılıyor); açıkken kapat
        android.net.wifi.WifiManager wm = (android.net.wifi.WifiManager) getApplicationContext().getSystemService(WIFI_SERVICE);
        wifiLock = wm.createWifiLock(Build.VERSION.SDK_INT >= 29 ? android.net.wifi.WifiManager.WIFI_MODE_FULL_LOW_LATENCY
                : android.net.wifi.WifiManager.WIFI_MODE_FULL_HIGH_PERF, TAG);
        wifiLock.acquire();
        prefs = getSharedPreferences("ayarlar", MODE_PRIVATE);
        audioOn = prefs.getBoolean("ses", true);
        fill = prefs.getBoolean("doldur", false);

        root = new FrameLayout(this);
        root.setBackgroundColor(Color.BLACK);
        video = new TextureView(this);
        video.setSurfaceTextureListener(this);
        root.addView(video, new FrameLayout.LayoutParams(-1, -1, Gravity.CENTER));
        cursor = new ImageView(this);
        cursor.setVisibility(View.GONE);
        root.addView(cursor, new FrameLayout.LayoutParams(1, 1));
        waiting = waitingScreen();
        root.addView(waiting, new FrameLayout.LayoutParams(-1, -1));
        root.addOnLayoutChangeListener((v, l, t, r, bt, ol, ot, or, ob) -> applyScale());
        setContentView(root);
    }

    View waitingScreen() {
        LinearLayout box = new LinearLayout(this);
        box.setOrientation(LinearLayout.VERTICAL);
        box.setGravity(Gravity.CENTER);
        box.setBackgroundColor(Color.rgb(16, 18, 32));
        TextView title = text("Ekran Yansıt", 44, Color.WHITE);
        status = text("Mac'ten bağlantı bekleniyor\n" + ip(), 26, Color.rgb(170, 190, 255));
        TextView hint = text("Ayarlar için OK veya Menü tuşuna bas", 18, Color.GRAY);
        ImageView logo = new ImageView(this);
        logo.setImageDrawable(getApplicationInfo().loadIcon(getPackageManager())); // manifest'teki uygulama simgesi
        int px = Math.round(160 * getResources().getDisplayMetrics().density);
        box.addView(logo, new LinearLayout.LayoutParams(px, px));
        box.addView(title);
        box.addView(status);
        box.addView(hint);
        return box;
    }

    TextView text(String s, int sp, int color) {
        TextView t = new TextView(this);
        t.setText(s);
        t.setTextSize(sp);
        t.setTextColor(color);
        t.setGravity(Gravity.CENTER);
        t.setPadding(0, 16, 0, 16);
        return t;
    }

    static String ip() {
        try {
            for (NetworkInterface n : Collections.list(NetworkInterface.getNetworkInterfaces()))
                for (InetAddress a : Collections.list(n.getInetAddresses()))
                    if (a instanceof Inet4Address && !a.isLoopbackAddress()) return a.getHostAddress() + ":" + PORT;
        } catch (Exception ignored) {}
        return "IP bulunamadı";
    }

    @Override
    public boolean onKeyDown(int code, KeyEvent e) {
        if (code == KeyEvent.KEYCODE_MENU || code == KeyEvent.KEYCODE_DPAD_CENTER || code == KeyEvent.KEYCODE_ENTER) {
            showSettings();
            return true;
        }
        return super.onKeyDown(code, e);
    }

    void showSettings() {
        String[] items = {"Ses: " + (audioOn ? "Açık" : "Kapalı"), "Görüntü: " + (fill ? "Doldur (kırp)" : "Sığdır")};
        new AlertDialog.Builder(this, android.R.style.Theme_DeviceDefault_Dialog_Alert)
                .setTitle("Ayarlar")
                .setItems(items, (d, which) -> {
                    if (which == 0) audioOn = !audioOn;
                    else { fill = !fill; applyScale(); }
                    prefs.edit().putBoolean("ses", audioOn).putBoolean("doldur", fill).apply();
                    showSettings(); // değişikliği hemen göster
                })
                .setNegativeButton("Kapat", null)
                .show();
    }

    // Videoyu ekrana sığdır (kenarda siyah bant) ya da doldur (taşan kısım kırpılır), oranı bozmadan
    void applyScale() {
        int W = root.getWidth(), H = root.getHeight();
        if (videoW == 0 || W == 0) return;
        float k = fill ? Math.max((float) W / videoW, (float) H / videoH) : Math.min((float) W / videoW, (float) H / videoH);
        FrameLayout.LayoutParams lp = new FrameLayout.LayoutParams(Math.round(videoW * k), Math.round(videoH * k), Gravity.CENTER);
        if (lp.width != video.getWidth() || lp.height != video.getHeight()) video.setLayoutParams(lp);
    }

    // x,y: imlecin video içindeki yeri (0…1); negatifse imleç başka ekranda
    void placeCursor(float x, float y) {
        lastX = x; lastY = y;
        android.graphics.drawable.Drawable d = cursor.getDrawable();
        if (x < 0 || normW <= 0 || d == null || video.getWidth() == 0) { cursor.setVisibility(View.GONE); return; }
        int w = Math.max(8, Math.round(normW * video.getWidth()));
        int h = Math.round(w * (float) d.getIntrinsicHeight() / d.getIntrinsicWidth());
        FrameLayout.LayoutParams lp = (FrameLayout.LayoutParams) cursor.getLayoutParams();
        if (lp.width != w || lp.height != h) { lp.width = w; lp.height = h; cursor.setLayoutParams(lp); }
        cursor.setX(video.getX() + x * video.getWidth() - hotX * w);
        cursor.setY(video.getY() + y * video.getHeight() - hotY * h);
        cursor.setVisibility(View.VISIBLE);
    }

    void setStreaming(boolean on, int w, int h) {
        runOnUiThread(() -> {
            if (on) { videoW = w; videoH = h; applyScale(); }
            waiting.setVisibility(on ? View.GONE : View.VISIBLE);
            if (!on) cursor.setVisibility(View.GONE);
        });
    }

    @Override public void onSurfaceTextureAvailable(SurfaceTexture st, int w, int h) {
        surface = new Surface(st);
        if (server == null) new Thread(this::serve, "server").start();
    }
    @Override public void onSurfaceTextureSizeChanged(SurfaceTexture st, int w, int h) {}
    @Override public boolean onSurfaceTextureDestroyed(SurfaceTexture st) { closeServer(); surface = null; return true; }
    @Override public void onSurfaceTextureUpdated(SurfaceTexture st) {}
    @Override protected void onDestroy() { closeServer(); if (wifiLock.isHeld()) wifiLock.release(); super.onDestroy(); }

    void closeServer() {
        try { if (server != null) server.close(); } catch (Exception ignored) {}
        server = null;
    }

    void serve() {
        try (ServerSocket ss = new ServerSocket()) {
            ss.setReuseAddress(true);
            ss.bind(new java.net.InetSocketAddress(PORT));
            server = ss;
            while (!ss.isClosed()) {
                try (Socket s = ss.accept()) {
                    s.setTcpNoDelay(true);
                    play(new DataInputStream(new BufferedInputStream(s.getInputStream(), 1 << 16)));
                } catch (Exception e) {
                    Log.i(TAG, "bağlantı bitti: " + e);
                } finally {
                    setStreaming(false, 0, 0);
                }
            }
        } catch (Exception e) {
            Log.i(TAG, "sunucu kapandı: " + e);
        }
    }

    void play(DataInputStream in) throws Exception {
        MediaCodec codec = null;
        boolean needKey = false; // bir kare atıldıysa bozuk görüntü yerine temiz anahtar kareyi bekle
        int bufSize = Math.max(AudioTrack.getMinBufferSize(48000, AudioFormat.CHANNEL_OUT_STEREO, AudioFormat.ENCODING_PCM_16BIT), 16384);
        AudioTrack audio = new AudioTrack(AudioManager.STREAM_MUSIC, 48000, AudioFormat.CHANNEL_OUT_STEREO,
                AudioFormat.ENCODING_PCM_16BIT, bufSize, AudioTrack.MODE_STREAM);
        audio.play();
        LinkedBlockingQueue<byte[]> audioQ = new LinkedBlockingQueue<>();
        final boolean[] running = {true};
        Thread audioThread = new Thread(() -> {
            try {
                while (running[0]) {
                    byte[] a = audioQ.poll(100, TimeUnit.MILLISECONDS);
                    if (a != null) audio.write(a, 0, a.length);
                }
            } catch (InterruptedException ignored) {}
        }, "audio");
        audioThread.start();
        long statT = System.currentTimeMillis(); int vIn = 0, vDrop = 0, aIn = 0; long maxGap = 0, lastPkt = statT; // tanı sayaçları
        try {
            while (true) {
                int type = in.readUnsignedByte();
                long pts = in.readLong();
                int len = in.readInt();
                if (len < 0 || len > 16 << 20) throw new IllegalStateException("bozuk paket: " + len);
                byte[] buf = new byte[len];
                in.readFully(buf);
                long now = System.currentTimeMillis();
                maxGap = Math.max(maxGap, now - lastPkt); lastPkt = now;
                if (now - statT >= 2000) {
                    Log.i(TAG, "stat video=" + vIn + " atılan=" + vDrop + " gösterilen=" + RENDERED.getAndSet(0) + " ses=" + aIn + " sesKuyruk=" + audioQ.size() + " maxBoşluk=" + maxGap + "ms");
                    statT = now; vIn = vDrop = aIn = 0; maxGap = 0;
                }
                if (type == 0 && codec == null) {
                    ByteBuffer bb = ByteBuffer.wrap(buf);
                    int w = bb.getInt(), h = bb.getInt();
                    MediaFormat f = MediaFormat.createVideoFormat("video/avc", w, h);
                    if (Build.VERSION.SDK_INT >= 30) f.setInteger(MediaFormat.KEY_LOW_LATENCY, 1);
                    codec = MediaCodec.createDecoderByType("video/avc");
                    codec.configure(f, surface, null, 0);
                    codec.start();
                    startDrain(codec, running);
                    queue(codec, buf, 8, len - 8, pts, MediaCodec.BUFFER_FLAG_CODEC_CONFIG);
                    setStreaming(true, w, h);
                } else if (type == 1 && codec != null) {
                    vIn++;
                    if (needKey && !isKeyFrame(buf)) { vDrop++; continue; }
                    needKey = !queue(codec, buf, 0, len, pts, 0);
                    if (needKey) vDrop++;
                } else if (type == 3) {
                    ByteBuffer bb = ByteBuffer.wrap(buf);
                    float x = bb.getFloat(), y = bb.getFloat();
                    runOnUiThread(() -> placeCursor(x, y));
                } else if (type == 4) {
                    ByteBuffer bb = ByteBuffer.wrap(buf);
                    float hx = bb.getFloat(), hy = bb.getFloat(), nw = bb.getFloat();
                    Bitmap bm = BitmapFactory.decodeByteArray(buf, 12, len - 12);
                    if (bm != null) runOnUiThread(() -> { hotX = hx; hotY = hy; normW = nw; cursor.setImageBitmap(bm); placeCursor(lastX, lastY); });
                } else if (type == 2 && audioOn) {
                    aIn++;
                    audioQ.offer(buf);
                    while (audioQ.size() > MAX_AUDIO_CHUNKS) audioQ.poll();
                }
            }
        } finally {
            running[0] = false;
            audioThread.interrupt();
            audioThread.join(500);
            audio.release();
            if (codec != null) { try { codec.stop(); } catch (Exception ignored) {} codec.release(); }
        }
    }

    static final java.util.concurrent.atomic.AtomicInteger RENDERED = new java.util.concurrent.atomic.AtomicInteger();

    static boolean queue(MediaCodec c, byte[] buf, int off, int n, long pts, int flags) {
        int i = c.dequeueInputBuffer(500_000); // atmak görüntüyü bozar; çözücü boşalana kadar bekle
        if (i < 0) return false;
        ByteBuffer b = c.getInputBuffer(i);
        b.clear();
        b.put(buf, off, n);
        c.queueInputBuffer(i, 0, n, pts, flags);
        return true;
    }

    /** Mac anahtar karelerin başına SPS (NAL tip 7) koyar: 00 00 00 01 67 ... */
    static boolean isKeyFrame(byte[] b) { return b.length > 4 && (b[4] & 0x1f) == 7; }

    static void startDrain(MediaCodec c, boolean[] running) {
        new Thread(() -> {
            MediaCodec.BufferInfo info = new MediaCodec.BufferInfo();
            Pacer pacer = new Pacer();
            try {
                while (running[0]) {
                    int o = c.dequeueOutputBuffer(info, 100_000);
                    if (o >= 0) {
                        long wait = pacer.renderAt(info.presentationTimeUs, System.nanoTime()) - System.nanoTime();
                        if (wait > 0) Thread.sleep(wait / 1_000_000, (int) (wait % 1_000_000));
                        c.releaseOutputBuffer(o, true); // TextureView zaman damgasını dikkate almaz; gösterim anını burada bekliyoruz
                        RENDERED.incrementAndGet();
                    }
                }
            } catch (IllegalStateException | InterruptedException ignored) {} // codec kapatıldı
        }, "drain").start();
    }
}
