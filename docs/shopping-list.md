# Ortak alışveriş listesi

Ailenin tek, ortak listesi. Biri ekler, markette olan işaretler; açık uygulamalar `/hubs/chat` üzerinden
`ShoppingChanged` olayıyla anında yenilenir.

- `POST /api/v1/families/{familyId}/shopping/items` `{ "text": "süt, ekmek\n1,5 kg elma" }`: virgül ve satır
  sonundan bölünür (ondalık virgül bölünmez). Listede açık duran aynı ürün (büyük/küçük harf fark etmez) ikinci kez
  eklenmez; yanıtta `alreadyOnList` olarak döner.
- `PATCH .../items/{id}` `{ "checked": true }` ya da `{ "quantity": "2 kg" }`, `DELETE .../items/{id}`,
  `POST .../clear-checked`.
- `POST .../heading-out`: "Alışverişe çıkıyorum" diğer yetişkinlere push gönderir (`kind=ShoppingHeadingOut`).
  Kişi başına 15 dakikada bir.
- Uygulama işareti hemen gösterir (markette çekim zayıf olabilir), sunucu reddederse geri alır.
