# Uyku kaydı

- "Uyudu" / "Uyandı" dokunuşları (`POST .../children/{childId}/sleep/start|stop`). Çocuk başına bir açık uyku
  (kısmi unique index); iki ebeveyn aynı anda basarsa tek kayıt kalır. Değişiklikler `/hubs/chat` üzerinden
  `SleepChanged` ile anında gider.
- Tür (gece / gündüz uykusu) verilmezse aile saatine göre tahmin edilir: 18:00–06:00 arası başlayan gece sayılır.
- **Uyku günü 06:00'da başlar.** 21:00'de başlayan ve 00:30'da başlayan uyku aynı akşamın gününe yazılır.
- Sonradan uyku eklenebilir (`POST .../sleep/entries`); başka bir uykuyla çakışan kayıt reddedilir (422).
  Açık kalan uyku 16 saatten fazla sayılmaz.
- `GET .../children/{childId}/sleep?days=7`: günlük gece ve gündüz dakikaları, kayıtlar ve ortalamalar
  (ortalamaya bugün ve kaydı olmayan günler girmez).
