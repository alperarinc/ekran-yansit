package com.alper.ekranyansit;

/**
 * Titreşim tamponu: kareleri Mac'teki çekim aralıklarıyla, sabit bir gecikmeyle gösterir.
 * Wi-Fi paketleri topluca (ör. 100 ms'de bir) getirdiğinde görüntünün takılmasını önler.
 * Ağ tamponu aşan bir takılma yaşarsa gecikme ikiye katlanır (en fazla MAX_DELAY_NS).
 */
public final class Pacer {
    public static final long START_DELAY_NS = 150_000_000L;
    public static final long MAX_DELAY_NS = 600_000_000L;
    private static final long LATE_NS = 50_000_000L;
    private long delay = START_DELAY_NS;
    private boolean aligned;
    private long base; // gösterim anı = base + pts

    public long delayNs() { return delay; }

    /** pts (µs) için System.nanoTime() cinsinden gösterim anı */
    public long renderAt(long ptsUs, long nowNs) {
        long t = base + ptsUs * 1000;
        boolean late = aligned && t < nowNs - LATE_NS;
        // ilk kare, ağ takılmasıyla çok geç kalan ya da saat kayması/yeni oturumla çok ileri düşen kare: yeniden hizala
        if (!aligned || late || t > nowNs + 2 * MAX_DELAY_NS) {
            if (late) delay = Math.min(delay * 2, MAX_DELAY_NS);
            base = nowNs + delay - ptsUs * 1000;
            aligned = true;
            return nowNs + delay;
        }
        return Math.max(t, nowNs);
    }
}
