# Recurrence API probe

Explicit manual integration test, separate from Glitter and its automated fake-data tests.

Build with `bash Tests/Manual/build_recurrence_probe.sh`, then open
`build/RecurrenceProbe.app`. It requests its own Reminders permission and creates
one uniquely named temporary list in the default Reminders source. It only fetches
items in that list. No existing reminder items are read or modified. It removes
its test list after testing, unless an unrecognized item has appeared in the list.
Production app sources and binaries are not changed by the probe.

## Observed on 2026-11-09

macOS 27.2 (26B123), timezone Asia/Shanghai. Three all-day tasks: ordinary overdue,
daily due today, and daily overdue. Each scenario creates a task, completes it,
refetches after several delays, reopens the completed occurrence, then refetches.

- Ordinary overdue: the same item returns to incomplete, with the same due date.
- Daily (today and overdue): completion advances the original item's ID and
  recurrence rule to the next scheduled occurrence. A separate ID represents the
  completed occurrence, without a recurrence rule.
- Reopening that completed occurrence makes it incomplete but does not remove
  the next occurrence. Both remain incomplete, and the reopened older item has
  no recurrence rule. This is not equivalent to the Reminders app's Command-Z.
- The overdue test was due Nov 8; completion on Nov 9 produced a Nov 10 reminder.
- Test calendar removal was verified after all three scenarios.

Raw observations: `build/review/recurrence-api/probe-results.json`.
These results cover the tested OS/source and all-day daily recurrence only;
other account providers and recurrence types were not tested.

Do not implement a full Undo by merely setting the completed occurrence's
`isCompleted` to false. Do not infer an old/new recurrence relationship from title
alone. Exact restoration would require a separate, carefully validated design.

## Production mutation service validation

Build with `bash Tests/Manual/build_recurrence_probe.sh --writer` and open the
same probe bundle. This invokes `EventKitReminderMutation`, the actual write
service used by Glitter, against new fake items in its own temporary list.
It performs complete → incomplete → complete again for ordinary overdue,
daily due today, and daily overdue items. It also checks that using the stale
parent ID after recurrence advancement is rejected without modifying tomorrow.

All three scenarios passed on 2026-11-09, macOS 27.2. The next occurrence was
preserved after both uncompletion and recompletion, no extra recurrence was
created, and the test calendar was removed. Results are saved separately in
`build/review/recurrence-api/writer-results.json`; the original API experiment
remains in `probe-results.json`. Existing user reminder items were not fetched
or modified. Other providers and recurrence types were not tested.
