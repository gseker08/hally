# Kilit ekranı bildirimleri (Android)

Uygulamanın kendi gösterdiği bildirimler (`flutter_local_notifications`). Kod:
`mobile/lib/features/notifications/device_notifications.dart`.

## Ekran süresi sayacı

- Bir çocuğun sayacını **sen başlattıysan**, sayaç çalıştığı sürece kilit ekranında ve bildirim panelinde
  kaydırılamayan bir bildirim durur: "Ada · ekran süresi", canlı akan süre (bugünün toplamı) ve **Durdur** düğmesi.
- Diğer ebeveynin başlattığı sayaç onun telefonunda görünür; senin telefonunda uygulama içinde görünür. Böylece
  uygulama kapalıyken başka telefonda durdurulan bir sayaç burada eskimiş bildirim bırakmaz.
- **Durdur** uygulamayı açmadan sunucuya `POST .../screen-time/stop` gönderir (arka plan isolate'i). Bağlantı yoksa
  bildirim kalır ve "Kaydedilemedi" bildirimi çıkar.
- Uygulama açıkken sayaç iki telefondan birinde durdurulursa (SignalR) bildirim kalkar. Sunucunun 8 saatlik üst
  sınırında bildirim kendiliğinden kapanır. Uygulama açılınca eskimiş bildirimler temizlenir.
- Çıkış yapınca Hally'nin tüm bildirimleri kaldırılır.
- Android 13+ bildirim iznini ister. iPhone (Live Activities) henüz yok; Mac ve Apple hesabı gerekir.

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
