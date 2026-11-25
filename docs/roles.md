# Aile rolleri

| Rol | Kim | Ne yapabilir |
| --- | --- | --- |
| **Ebeveyn** (`Owner`, `Adult`) | Anne, baba | Her şey. İki ebeveyn eşittir; `Owner` yalnızca aileyi kuran kişiyi gösterir. |
| **Bakıcı** (`Caregiver`) | Dadı, büyükanne, yardımcı | Günlük işler: Bugün, takvim ve görevleri görmek, görev tamamlamak, ilaç dozu, beslenme, uyku, ekran ve ders süresi, okul nöbeti işaretleme, alışveriş listesi, mesajlar. |
| **Çocuk** | Çocuğun kendi telefonu | Sonraki PR'larda (çocuk modu). |

## Sunucuda nasıl uygulanıyor

- `Policies.FamilyMember` önce üyeliği kontrol eder (`FamilyMemberHandler`).
- Bakıcılar için **varsayılan kapalı**: bir endpoint ya da controller `[CaregiverAllowed]` taşımıyorsa bakıcı 403 alır.
  Yeni bir özellik eklendiğinde bakıcıya açmak bilinçli bir karardır.
- Endpoint içinde role göre veri kısmak için `HttpContext.IsParent()` kullanılır (örnek: içgörülerde harcama ve sağlık
  bakıcıya boş gelir).
- Bakıcı harcama paylaşımına dahil edilmez, ebeveyn sayısı (plan limiti) içinde sayılmaz; ayrı sınır `Family.MaxCaregivers` (4).
- Son ebeveyn ayrılırsa aile silinir; bakıcı tek başına aile tutamaz.

## Davet

`POST /api/v1/families/{familyId}/invitations` gövdesi isteğe bağlı: `{ "role": "caregiver" }` ya da `{ "role": "parent" }`
(varsayılan). Yanıt ve önizleme (`GET /api/v1/invitations/{token}`) `role` alanını döner. Davet etmek yalnızca ebeveynlere açık.

## Bakıcı erişimi (süre, çocuklar, sağlık)

`FamilyMember` üzerinde, yalnızca bakıcılar için:

- `AccessUntil`: erişimin bittiği an (null = ebeveyn kaldırana kadar). Geçtiyse her istek 403 alır, `/me` aileyi göstermez,
  saatlik `caregiver-expiry` işi bakıcıyı aileden çıkarır (ayrılmakla aynı temizlik).
- `ChildIds`: baktığı çocuklar (boş = hepsi). Rotada `{childId}` varsa ve listede yoksa 403. Listeler (Bugün, görevler,
  etkinlikler, ekran/uyku/beslenme/ders, yıldızlar, ilaçlar, alışkanlıklar, aile çocukları) bakıcıya göre süzülür; çocuk
  etiketi olmayan (tüm aile) görev ve etkinlikler görünür kalır.
- `CanSeeHealth`: sağlık kartını okuyabilir mi (varsayılan kapalı). `[CaregiverAllowed(Health = true)]` ile kontrol edilir.
  Bakıcı sağlık kartını hiçbir zaman düzenleyemez.

Uç noktalar (yalnızca ebeveyn):

| Yöntem | Yol | Açıklama |
| --- | --- | --- |
| POST | `/api/v1/families/{familyId}/invitations` | `{ role: "caregiver", accessUntil, childIds, canSeeHealth }` |
| PUT | `/api/v1/families/{familyId}/members/{userId}/access` | Aynı üç alanı değiştirir |
| DELETE | `/api/v1/families/{familyId}/members/{userId}` | Bakıcıyı hemen çıkarır (ebeveyn çıkarılamaz, 422) |

Bakıcıya Bugün ekranında Hally önerileri gösterilmez.
