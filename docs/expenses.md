# Expense sharing

Parents log family spending (school trip, doctor, a new coat) with who paid it. Each expense is split **equally between the
family's adults** at the time it was added, and Hally shows who owes whom. Hally moves no money; "I paid" only records a payment.

## Rules

- Amount: more than 0, at most 1,000,000, 2 decimals. Currency is TRY for now.
- Category: School, Health, Clothes, Activity, Food or Other. Optional child and note.
- The split is fixed when the expense is added (`shared_with`, a uuid[] of the adults then). A parent who joins later does not owe for older costs.
- Equal shares are rounded to kuruş; the leftover kuruş goes to the payer, so the shares always add up to the amount.
- Balance (all time, not per month): what you paid minus your shares, plus payments you sent, minus payments you received. Positive means the others owe you.
- Suggestion: the adult who owes most pays the adult who is owed most, for the smaller of the two amounts. With two parents this settles everything.
- A payment is recorded **from the signed-in adult** to another adult. Deleting an expense or payment recomputes the balance.

## API

| Method | Path | Notes |
| --- | --- | --- |
| GET | `/api/v1/families/{familyId}/expenses?month=yyyy-MM` | Month total, per category, expenses (with `myShare`), payments, all-time balances, suggestion |
| POST | `.../expenses` | `{ title, amount, category, date?, paidByUserId?, childId?, note? }`, 201 with the month |
| DELETE | `.../expenses/{expenseId}` | Returns the month |
| POST | `.../expenses/settlements` | `{ toUserId, amount }`, from me; 201 with the month |
| DELETE | `.../expenses/settlements/{settlementId}` | Returns the month |

Every change sends `ExpensesChanged { familyId }` over `/hubs/chat`.

## App

Family → Expenses: month switcher, the balance card ("Mehmet, Ayşe kişisine 349,75 ₺ borçlu" with an **Ödedim** button for the
one who owes), category totals, the list (swipe to delete) and payments. Amounts accept `12,50`, `12.5` and `1.250,00`.
