# Ekran Yansıt

Mac ekranını **sesiyle birlikte** Android TV kutusuna yansıtan ya da TV'yi **ikinci ekran** olarak kullanan, açık kaynak bir uygulama çifti. Mac ile TV arasında dosya taşıma da yapabilir.

- **Yansıt**: Mac ekranının aynısı TV'de görünür.
- **Genişlet**: TV, Mac'in ikinci monitörü olur (sanal ekran).
- **Ses**: Sistem sesi de TV'ye gider, ek sürücü gerekmez.
- **Akıcı görüntü**: Görüntü donanımda H.264 ile sıkıştırılır. Wi-Fi'daki takılmaları titreşim tamponu yumuşatır.
- **Hızlı imleç**: İmleç ayrı gönderilir ve TV'de anında çizilir.
- **Dosyalar**: Mac'ten TV'ye sürükle-bırak. TV'nin klasörlerinde gezip Mac'e indirebilirsin.
- **Ayarlar**:
  - Mac'te: çözünürlük (720p–4K), kare hızı (15/30/60 fps), bit hızı.
  - TV'de: ses açık/kapalı, görüntüyü sığdır/doldur.

## Gereksinimler

- **Mac:** macOS 14 veya sonrası, Apple Silicon.
- **TV:** Android TV, Android 7 veya sonrası.
- **Ağ:** Mac ve TV aynı ağda olmalı. TV için 5 GHz Wi-Fi ya da kablo önerilir.

## Kurulum (hazır sürüm)

[Releases](../../releases) sayfasından iki dosyayı indir.

### TV

`EkranYansit.apk` dosyasını TV'ye kur. Üç yol var:

- **adb ile:** TV'de Ayarlar › Cihaz Tercihleri › Geliştirici seçenekleri › **USB/Ağ hata ayıklama**'yı aç, sonra:
  ```sh
  adb connect <TV-IP>:5555
  adb install EkranYansit.apk
  ```
- **USB bellekle:** APK'yı bir USB belleğe kopyala ve TV'de bir dosya yöneticisiyle aç.
- **Downloader uygulamasıyla:** TV'deki Downloader uygulamasına APK'nın bağlantısını gir.

### Mac

1. `EkranYansit-macOS.zip`'i aç ve `EkranYansit.app`'i **Uygulamalar** klasörüne taşı.
2. Uygulama Apple tarafından onaylı (notarize edilmiş) değil. İlk açılışta macOS engellerse uygulamaya **sağ tıklayıp › Aç** de, ya da şunu çalıştır:
   ```sh
   xattr -dr com.apple.quarantine /Applications/EkranYansit.app
   ```
3. **Ayarlar** sekmesine TV'nin IP adresini yaz. Adres TV'deki bekleme ekranında görünür.
4. **Başlat**'a bas. İlk seferde macOS **Ekran ve Sistem Sesi Kaydı** izni ister. İzni ver ve uygulamayı yeniden aç.

### Neler kendiliğinden çalışır

- TV'de adb (ağ hata ayıklama) açıksa, Mac uygulaması TV'deki alıcıyı kendisi başlatır ve **Dosyalar** sekmesi çalışır.
- adb kapalıysa TV'de "Ekran Yansıt"ı kumandayla kendin aç. Yansıtma çalışır, ama dosya taşıma çalışmaz.

## Kaynaktan derleme

Gerekenler: Xcode, Android SDK (build-tools ve platform), Java 11 veya sonrası.

```sh
./install.sh <TV-IP>
```

Bu tek komut şunları yapar:

1. Simgeleri üretir.
2. APK'yı gradle kullanmadan derler: `aapt2` + `javac` + `d8`.
3. APK'yı TV'ye kurar.
4. Mac uygulamasını derler.
5. Mac uygulamasını yerel bir sertifikayla imzalar. İmza sabit kaldığı için Ekran Kaydı izni yeniden derlemelerden sonra da korunur.
6. Uygulamayı `/Applications` klasörüne kopyalar.

Ayrıca iki öz-test çalışır:
- Mac tarafı: `--selftest`
- TV tarafı: `PacerCheck`

## Nasıl çalışır

```
Mac                                          TV (Android)
ScreenCaptureKit ─ ekran ─ VideoToolbox H.264 ─┐
                └─ ses (PCM 48 kHz) ───────────┼─ TCP :7070 ─▶ MediaCodec ─ titreşim tamponu ─ TextureView
imleç konumu + şekli (~100 Hz) ────────────────┘               AudioTrack · imleç katmanı
```

Her paket şu yapıdadır: `[tip u8][pts µs u64][uzunluk u32][veri]`.

| Tip | İçerik |
|---|---|
| 0 | Video ayarı (genişlik, yükseklik, SPS/PPS) |
| 1 | H.264 karesi (Annex-B) |
| 2 | Ses: PCM s16le, stereo |
| 3 | İmleç konumu |
| 4 | İmleç görseli (PNG) |

- **Genişlet modu**, macOS'un belgelenmemiş `CGVirtualDisplay` API'sini kullanır. Bir macOS güncellemesi bu modu bozabilir; Yansıt modu bundan etkilenmez.
- **Dosya taşıma**, `adb push` ve `adb pull` ile yapılır.

## Bilinen sınırlar

- **Şifreleme yok:** Bağlantı şifrelenmez. Sadece güvendiğin ev ağında kullan.
- **Tek TV:** Aynı anda tek bir TV'ye yansıtılır.
- **Gecikme:** Yaklaşık 150–600 ms. Tampon ağın durumuna göre kendini ayarlar.
- **Mac Wi-Fi takılmaları:** macOS'ta AirDrop ve Handoff'un kullandığı AWDL arayüzü Wi-Fi'da periyodik takılmalara yol açabilir. Yansıtma sırasında `sudo ifconfig awdl0 down` ile kapatabilirsin.

## Lisans

[MIT](LICENSE)
