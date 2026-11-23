# Kilit ekranı bildirimleri (Android)

Uygulamanın kendi gösterdiği bildirimler (`flutter_local_notifications`). Kod:
`mobile/lib/features/notifications/device_notifications.dart`.

## Çalışan sayaçlar (ekran süresi, ödev/okuma, uyku)

- Bir sayacı **sen başlattıysan** (ekran süresi, ödev, kitap okuma ya da uyku), sayaç çalıştığı sürece kilit
  ekranında ve bildirim panelinde kaydırılamayan bir bildirim durur: "Ada · ekran süresi", canlı akan süre ve
  **Durdur** düğmesi. Ekran süresi ve ödev/okuma için süre bugünün toplamıdır, uyku için bu uykunun süresi.
- Android 16 ve sonrası: bildirim "canlı güncelleme" olarak istenir (`requestPromotedOngoing`,
  `POST_PROMOTED_NOTIFICATIONS`), süre üst çubukta küçük bir rozet olarak da görünür. Eski sürümlerde yalnızca
  bildirim vardır.
- Emzirmenin çalışan bir sayacı yok (kayıt sonradan giriliyor), o yüzden burada değil.
- Diğer ebeveynin başlattığı sayaç onun telefonunda bildirim olur; senin telefonunda uygulama içinde ve
  "Şu an" widget'ında görünür. Böylece uygulama kapalıyken başka telefonda durdurulan bir sayaç burada eskimiş
  bildirim bırakmaz. (Sunucu bunun için `startedByUserId` döner: ekran süresi, ödev/okuma, uyku.)
- **Durdur** uygulamayı açmadan sunucuya ilgili `.../stop` isteğini gönderir (arka plan isolate'i). Bağlantı
  yoksa bildirim kalır ve "Kaydedilemedi" bildirimi çıkar.
- Uygulama açıkken sayaç iki telefondan birinde durdurulursa (SignalR) bildirim kalkar. Sunucunun üst sınırında
  (ekran süresi 8 sa, ödev/okuma 4 sa) bildirim kendiliğinden kapanır. Uygulama açılınca eskimiş bildirimler
  temizlenir. Çıkış yapınca Hally'nin tüm bildirimleri kaldırılır.
- iPhone (Live Activities) henüz yok; Mac ve Apple hesabı gerekir.

## "Şu an" widget'ı

- Ana ekranda ailenin **tüm** çalışan sayaçları (en çok 3 satır), her satırda canlı süre (Android Chronometer,
  uygulama kapalıyken de akar) ve **Durdur**. Dokununca uygulama açılır.
- Kod: `lib/features/home/now_widget.dart`, `NowWidgetProvider.kt`, `res/layout/now_widget.xml`.
- Durdur, `home_widget` arka plan geri çağrısıyla (`hallyWidgetAction`) sayacı durdurur, satırı kaldırır ve
  bildirimi kapatır. Sunucu sayacın zaten durmuş olduğunu söylerse satır yine kalkar.
- Sınır: başka telefonda durdurulan bir sayaç, bu telefonda uygulama kapalıyken widget'ta kalır; uygulama bir
  sonraki açılışta ya da o satırın Durdur'una basınca düzelir. Üst sınırı geçen sayaç kendiliğinden gizlenir.
- Eklemek için: ana ekranda uzun bas → Widgets → Hally → "Şu an".

## İlaç hatırlatması ("Verdim")

- Sunucunun `MedicationDueJob`'u sonraki doz zamanı gelince herkese hatırlatır (`docs/medications.md`). Android'e bu
  push **yalnızca veri** olarak gider (`PushMessage.AppDrawsOnAndroid`; başlık ve metin `data` içinde,
  `medicationId` ile). Bildirimi uygulama kendisi çizer: kilit ekranında "Ela: Ateş şurubu zamanı" ve
  **Verdim** düğmesi. iPhone normal uyarı alır (`apns.alert`).
- **Verdim**, uygulamayı açmadan dozu kaydeder (`force: false`). Doz erken ise (diğer ebeveyn az önce verdiyse ya
  da günlük sınır dolduysa) kilit ekranından **asla** zorla kaydedilmez: hatırlatma kalkar ve "Doz kaydedilmedi ·
  Son doz: 14:05 · Mehmet" yazar. Gerekirse uygulamadan kaydedilir (orada "yine de kaydet" sorusu var).
- Diğer ebeveyn dozu verince (`kind=MedicationGiven`) bu telefondaki hatırlatma kalkar.
- Uygulama açıkken gelen hatırlatma da bildirim paneline Verdim düğmesiyle düşer (snack bar yerine).
- Bildirim kanalı "İlaç hatırlatmaları" yüksek önemdedir; ilaç adı, kullanıcı "hassas içeriği gizle" seçtiyse
  kilitli ekranda gizlenir.
- Push için `google-services.json` gerekir (bkz. `docs/mobile/push.md`). Uygulamanın eski bir sürümü bu yalnızca
  veri push'unu göstermez; güncel sürümle sorun yok.
