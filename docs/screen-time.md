# Ekran süresi sayacı

Çocuk başına, elle başlatılıp durdurulan sayaç. Telefonu kısıtlamaz; yalnızca süreyi tutar ve ebeveynlere haber verir.

## Nasıl çalışır

- Sayaç **sunucuda** tutulur (`screen_time_sessions` tablosu). Bir çocuğun aynı anda en fazla bir çalışan sayacı olur
  (`ended_at IS NULL` üzerinde kısmi unique index). İki ebeveyn aynı anda "Başlat"a basarsa tek sayaç kalır.
- Her değişiklik `/hubs/chat` üzerinden `ScreenTimeChanged` olayıyla ailedeki tüm yetişkinlerin açık uygulamalarına gider.
  Uygulama, sunucudan aldığı süreye kendi saatine göre saniye ekleyerek sayar; telefon saati yanlış olsa da sonuç değişmez.
- Günler ailenin saat dilimine göre hesaplanır; gece yarısını geçen oturum iki güne bölünür.
- Unutulan sayaç 8 saat sonra saymayı bırakır ve dakikalık iş (`ScreenTimeGoalJob`) onu kapatır.
- Günlük hedef (`children.daily_screen_minutes`, 5–1440 dk) dolunca her yetişkine bir bildirim (gelen kutusu + push,
  `kind=ScreenTimeGoal`) gider. Çocuk başına günde bir kez.

## API

| Yöntem | Yol | Açıklama |
| --- | --- | --- |
| GET | `/api/v1/families/{familyId}/screen-time` | Bugünkü süre ve çalışan sayaçlar |
| GET | `/api/v1/families/{familyId}/screen-time/week?start=yyyy-MM-dd` | Haftalık özet (varsayılan bu haftanın pazartesisi) |
| POST | `.../children/{childId}/screen-time/start` | Başlat (zaten çalışıyorsa hata değil) |
| POST | `.../children/{childId}/screen-time/stop` | Durdur |
| POST | `.../children/{childId}/screen-time/entries` | `{ "minutes": 30 }` geçmişe dönük süre ekle |
| PUT | `.../children/{childId}/screen-time/goal` | `{ "dailyMinutes": 90 }` ya da `null` |
