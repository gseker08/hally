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
