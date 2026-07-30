# ConvoLab iOS agent instructions

## Physical device builds

- Always use the production API (`https://convo-lab.com`) for any build installed on
  Andrew's physical iPhone or iPad.
- The checked-in Debug configuration uses the local API for simulator development. Never
  install that default Debug configuration on a physical device. Use Release or explicitly
  override `API_BASE_URL` with the production URL, then verify the built app's `Info.plist`
  before installation.
