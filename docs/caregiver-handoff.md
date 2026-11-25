# Bakıcı devir teslim raporu (caregiver handoff)

At the end of the day a caregiver taps **Günü bitir** on Today (one row per child they look after) and sends parents
a report. Route `/handoff/:childId`; history `/handoffs?childId=` (from the child's insights page and the push).

API (`/api/v1/families/{familyId}`, caregivers allowed and scoped to their children):

- `GET children/{childId}/handoff/draft` → today's live summary (+ the report already sent today, if any).
- `POST children/{childId}/handoffs` `{ incidents: ["Fall"|"Fever"|"Other"], note }` → saves today's report (one per
  child/day/author; sending again replaces it) and pushes parents (`kind=HandoffReport`).
- `POST handoffs/{id}/photo` (multipart `file`, author only) / `GET handoffs/{id}/photo` (encrypted storage).
- `GET handoffs?childId&day&limit` → newest first; caregivers only see their own.
- `POST handoffs/{id}/thanks` (parents) → hides the Today card and pushes the caregiver (`kind=HandoffThanks`).

The summary is a snapshot (jsonb) of the child's feeding, sleep (started that day), medicine doses and screen time
(the larger of timers and the paired child phone's own count). Incidents are shown in an orange box, never red.
