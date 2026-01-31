# ThunderRAG (Thunderbird)

This add-on registers a **custom message filter action** named `ThunderRAG`.

When a filter runs, the action will POST the full raw message (RFC822 / `.eml`, including attachments) to the configured endpoint.

## Filter action argument

The action takes one argument:

- A URL (optionally without scheme), for example:
  - `http://localhost:8080/ingest`
  - `localhost:8080/ingest` (defaults to `http://`)

The add-on validates that the final URL is `http` or `https` and has a host.

## Payload

- Method: `POST`
- Content-Type: `message/rfc822`
- Body: raw message bytes (RFC822)
- Extra headers:
  - `X-Thunderbird-Message-Id`: value of the message-id header if available

## Install / Test

1. Create a ZIP with `manifest.json` at the root.
2. In Thunderbird:
   - `Tools` -> `Add-ons and Themes`
   - Click the gear icon -> `Install Add-on From File...`
   - Select the ZIP.
3. Create a Message Filter and pick the new action:
   - `ThunderRAG`
   - Set its value to your endpoint URL.

## Notes

- The action is implemented via a Thunderbird **Experiment API** and registers an `nsIMsgFilterCustomAction` with `MailServices.filters.addCustomAction()`.
- For manual ("Run Now") filters, the action is async and signals completion using the provided copy listener.
