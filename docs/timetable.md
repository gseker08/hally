# Ders programı (school timetable)

Each child has a weekly timetable (Monday–Friday × the family's bell times). A lesson can list items it needs
("👟 Eşofman" for Beden Eğitimi); the evening before a school day parents get "🎒 Yarın çantaya".

- **API:** `GET /api/v1/families/{f}/school` returns settings, breaks, all lessons and tomorrow's bags.
  `PUT .../school/settings`, `POST/DELETE .../school/breaks`, `PUT .../school/lessons` (empty subject clears a
  period), `POST .../school/children/{to}/copy-from/{from}` are parents only. Caregivers read the timetable of their
  children and can tick (`PUT .../school/bags/{child}/items`) and say "Hazırladık" (`POST .../bags/{child}/ready`).
- **Settings** (`SchoolPlan`, one per family, defaults until saved): bell times `HH:mm` going up (max 10), every-day
  items (max 6), reminder time (default 19:30, null = off), child phone shows the bag, quiet on official holidays.
- **School day:** Monday–Friday, not inside a `SchoolBreak`, and (if quiet on holidays) not a Turkish official holiday
  (`TurkishHolidays`: fixed dates plus Ramazan/Kurban Bayramı for 2026–2027; add new years there).
- **Bag** (`BagCheck` per child per day): tomorrow's lesson items, every-day items and exams that are tomorrow or
  whose study days include today (key `exam:{id}`). "Hazırladık" ticks everything.
- **Notifications** (job `school-evenings`, every 15 min): after the reminder time, one `SchoolBag` per parent per
  child with lessons tomorrow, unless that bag is ready. `targetId` = child id.
- **Child mode:** `ChildHomeDto.school` has today's lessons (the current one marked) and, if allowed, tomorrow's bag.
  `PUT /api/v1/child/school/bag/items` ticks; `POST /api/v1/child/school/bag/ready` ticks all and makes a
  `ClaimKind.Bag` claim worth 1 cherry (`PointKind.Bag`) with the usual approval. Child phones get no push.
- **App:** `lib/features/school/` – `/timetable?child=`, `/timetable/settings`, Today "Yarın çantaya" cards, Kids tile,
  focus shortcut under "Okul, sınav, ödev".
