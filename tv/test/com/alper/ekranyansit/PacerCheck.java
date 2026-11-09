package com.alper.ekranyansit;

// Çalıştır: java -cp build/classes tv/test/com/alper/ekranyansit/PacerCheck.java
public class PacerCheck {
    static void check(boolean ok, String what) { if (!ok) throw new AssertionError(what); }

    public static void main(String[] a) {
        long D = Pacer.START_DELAY_NS, ms = 1_000_000L;
        Pacer p = new Pacer();
        check(p.renderAt(1_000_000, 0) == D, "ilk kare DELAY sonra");
        // 3 kare aynı anda (toplu) gelse de 33 ms arayla dağıtılır
        long now = 10 * ms;
        check(p.renderAt(1_033_000, now) == D + 33 * ms, "2. kare yayıldı");
        check(p.renderAt(1_066_000, now) == D + 66 * ms, "3. kare yayıldı");
        // biraz geç kalan kare hemen gösterilir, gecikme artmaz
        check(p.renderAt(1_100_000, D + 120 * ms) == D + 120 * ms, "az geç: hemen");
        check(p.delayNs() == D, "az geçte gecikme sabit");
        // ağ 500 ms takıldı: yeniden hizala ve gecikmeyi ikiye katla
        long late = D + 700 * ms;
        check(p.renderAt(1_133_000, late) == late + 2 * D, "çok geç: yeniden hizala, 2x gecikme");
        // tekrar tekrar takılırsa tavanda durur
        for (int i = 0; i < 5; i++) p.renderAt(1_133_000, late += 2_000 * ms);
        check(p.delayNs() == Pacer.MAX_DELAY_NS, "gecikme tavanı");
        // Mac yeni oturum (pts ileri atladı): yeniden hizala, gecikme artmaz
        long d = p.delayNs();
        check(p.renderAt(999_000_000, late) == late + d, "pts sıçraması: yeniden hizala");
        System.out.println("pacer ok");
    }
}
