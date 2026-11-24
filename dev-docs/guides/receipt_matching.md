# Receipt matching

When someone sends a receipt to their receipt bin, `ReceiptService::Suggest` works out which of their card transactions that are missing a receipt it belongs to. This guide covers how that's put together and how to read what the experiment on top of it reports.

## The pieces

- `ReceiptService::Extract` reads the receipt's text into fields (merchant, total, date, card) and a suggested memo.
- `ReceiptService::Match` is a [Squishling](https://github.com/Coolhand-Labs/squishling) class: its Ruby code scores each candidate transaction and picks the closest one (`MAX_DISTANCE`). That Ruby code is what answers every call. The class runs in [apprentice mode](https://github.com/Coolhand-Labs/squishling/blob/main/docs/apprentice.md): when the experiment is on, an LLM (`gpt-5.6-terra`) reads the receipt's **image** alongside it and picks a transaction too, and the two picks are compared. The model never sees the OCR text or extracted fields, and its answer never reaches a user.
- `ReceiptMatch::Shadow` decides whether the model reads a receipt (only receipts still in the bin, with candidates, within an hourly limit), and gives the call an id of its own with `Squishling.with_call_id`.
- `ReceiptMatchRun` records each shadow run: what each path picked, and the Coolhand request id.
- `ReceiptMatchEvent` records what people do with a suggestion (accept, ignore, reverse, attach it themselves, delete the receipt, keep or edit the suggested memo). Each event is sent to Coolhand as feedback on the model request it says something about (`Receipt::SendMatchFeedbackJob`). Match events go on the `ReceiptService::Match` request; memo events go on the extraction request that wrote the memo.

## Turning it on

Everything (Coolhand capture, the shadow run, feedback) is behind one Flipper flag, `ReceiptMatch::FLAG`, enabled per receipt owner. It's off by default. Receipts hold personal and financial data, so confirm Coolhand's retention and deletion terms before enabling it for anyone outside the team. You also need `COOLHAND__API_KEY` set; without it Coolhand isn't started at all.

Coolhand is configured to capture nothing by default (`config/initializers/coolhand.rb`), so other LLM calls, like card grant pre-authorization, aren't sent to it. Only calls wrapped in `ReceiptMatch.capture` are.

## The ids

- The model request: `receipt-match:<uuid>.<n>`. The uuid is the `ReceiptMatchRun#call_id`; `n` counts requests within the call (a retry or escalation makes it more than 1), so feedback uses the run's recorded `request_id`.
- The extraction request: `receipt-extract:<receipt id>`.

Both are Coolhand `client_unique_id`s. Neither holds personal data, since they leave the app.

## Testing

`spec/support/squishling_support.rb` forbids provider calls in every spec and runs shadow runs inline. Script a model answer with `fake_squishling` (see `spec/services/receipt_service/match_spec.rb`). `spec/lib/receipt_match/coolhand_integration_spec.rb` exercises the real adapter, observer and Coolhand client with only the HTTP endpoints stubbed.
