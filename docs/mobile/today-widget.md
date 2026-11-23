# Android "Bugün" widget'ı

Ana ekranda bugünün sıradaki 3 etkinlik/görevini gösteren widget. Dokununca uygulama açılır.

- **Veri:** Uygulama Bugün ekranını her yüklediğinde (açılış, aşağı çekip yenileme, görev tamamlama, canlı
  değişiklik, uygulamaya geri dönüş) listeyi widget deposuna yazar (`lib/features/home/today_widget.dart`,
  `home_widget` paketi). Gecikmiş görevler widget'ta yok; widget bugünün geri kalanı içindir.
- **Sıra:** Saatli olanlar saat sırasıyla, sonra gün boyu etkinlikler, sonra saatsiz görevler. 3'ten fazlaysa
  "+N daha" yazar.
- **Uygulama kapalıyken:** Widget geçen öğeleri kendisi gizler (başladıktan 15 dk sonra). Uygulama her öğenin
  bitişine ve gece yarısından 1 dk sonrasına yeniden çizim planlar; sistem ayrıca 30 dakikada bir çizer.
  Önceki günden kalan bir liste asla gösterilmez, "Bugünü görmek için Hally'yi aç" yazar.
- **Yeni eklenenler:** Diğer ebeveynin eklediği bir etkinlik, uygulama bir sonraki açılışta widget'a gelir
  (sunucudan arka planda çekme yok).
- **Dil:** Metinler uygulamanın dilinde yazılır (Aile > Dil).
- Native taraf: `android/app/src/main/kotlin/app/hally/hally/TodayWidgetProvider.kt`,
  `res/layout/today_widget.xml`, `res/xml/today_widget_info.xml`. Çıkış yapınca widget temizlenir.
- iPhone widget'ı henüz yok (Xcode ve Mac gerekir).

## Emülatörde ekleme

Ana ekranda boş bir yere uzun bas → **Widgets** → listede **Hally**'yi bul → "Bugün" widget'ını tutup ana ekrana
sürükle. Widget'ı uzun basıp kenarlarından büyütebilirsin.

## iPhone

The same data drives the iPhone widget (`mobile/ios/HallyWidgets/TodayWidget.swift`), on the home screen and the lock screen. See `ios.md`.
