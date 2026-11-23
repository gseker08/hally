# İlaç takibi

Hangi çocuğa hangi ilaç, ne zaman ve kim tarafından verildi; erken doza karşı uyarı.

- **Hally doz önermez.** Aralığı (en az kaç saat) ve isteğe bağlı 24 saatlik üst sınırı ebeveyn doktorun ya da
  prospektüsün talimatına göre girer. Hally yalnızca kaydı tutar.
- Doz kaydı (`POST .../medications/{id}/doses`) aralıktan erken ya da günlük sınırın üstündeyse **kaydedilmez** ve
  `409` döner: son dozu kimin, ne zaman verdiği ve sonraki dozun ne zaman uygun olduğu gövdededir. Uygulama
  "Mehmet 14:05'te verdi, yine de kaydedilsin mi?" diye sorar. Onaylanırsa `force: true` ile kaydedilir ve dozda
  `overrodeWarning` işaretlenir.
- İki ebeveyn aynı anda basarsa ilaç satırı `SELECT ... FOR UPDATE` ile kilitlenir; ikincisi uyarıyı görür.
- Geriye dönük doz (`givenAt`) da her iki yöndeki dozlara göre kontrol edilir; gelecekteki doz reddedilir (422).
- Verilen doz diğer yetişkinlere push olarak gider (`kind=MedicationGiven`). Her değişiklik `/hubs/chat` üzerinden
  `MedicationChanged` olayıyla açık uygulamalara bildirilir.
- `RemindNextDose` açıksa dakikalık `MedicationDueJob`, sonraki doz zamanı gelince herkese hatırlatır
  (`kind=MedicationDue`, gelen kutusu + push). Her doz için bir kez ve en geç 1 saat içinde; yarım kalan bir kür
  günlerce hatırlatmaz.
- "Kür bitti" ilacı gizler (`active=false`), geçmiş kalır. Yanlış kayıt geçmişten geri alınabilir.
