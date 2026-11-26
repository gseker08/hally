# Sınav takvimi (exam calendar)

Parents add a child's exam (subject, date, optional time/lesson and topics). Each exam owns one calendar event tagged
with the child, so it shows in the calendar, on Today, in the morning summary and under the child filter.

- **API:** `GET/POST /api/v1/families/{f}/exams`, `GET/PUT/DELETE .../exams/{id}`, `PUT .../exams/{id}/result`.
  Caregivers can read exams (never results); everything else is parents only.
- **Calendar:** the event title is `📝 {subject} sınavı`. A slot like `10:30` makes a 40-minute timed event, anything
  else (`2. ders`) an all-day event. Moving the event in the calendar moves the exam; deleting it deletes the exam.
  `EventDto.examId` lets the app open the exam editor instead of the event editor.
- **Study evenings:** with `studyDaysBefore` (1, 2, 3 or 7) the app shows "📚 Çalışma zamanı" rows on those days.
  "Başlat" starts the homework timer with `examId`, so the minutes add up on the exam (`studySeconds`).
- **Notifications** (job `exam-evenings`, every 15 min, from 18:00 family time): `ExamStudy` on study evenings and
  `ExamResult` ("Nasıl geçti?") on the exam day until a result is saved. Parents only, once per evening.
- **Result:** Hard / Good / Great, optional score (0–100), optional cherries (`PointKind.Exam`), given once.
- **Child mode:** `ChildHomeDto.exams` lists the next 14 days. "Çalıştım" (`POST /api/v1/child/exams/{id}/studied`)
  is a `ClaimKind.Study` claim worth 1 cherry, once a day, with the usual parent approval.
- **Scanned notes:** an approved event proposal whose title looks like an exam ("Matematik sınavı", "İngilizce
  yazılısı") with exactly one child tagged also becomes an exam with a 3-day study reminder.
